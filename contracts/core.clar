;; BitSynth: Bitcoin-Backed Synthetic Assets
;; Core contract that allows users to mint synthetic assets backed by Bitcoin

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-collateral (err u101))
(define-constant err-minimum-mint (err u102))
(define-constant err-maximum-mint (err u103))
(define-constant err-invalid-asset (err u104))
(define-constant err-unsafe-ratio (err u105))
(define-constant err-not-found (err u106))
(define-constant err-unauthorized (err u107))
(define-constant err-price-expired (err u108))
(define-constant err-transfer-failed (err u109))
(define-constant err-position-not-closed (err u110))
(define-constant err-invalid-fee (err u111))
(define-constant err-governance-only (err u112))
(define-constant err-oracle-only (err u113))
(define-constant err-paused (err u114))
(define-constant err-cooldown-period (err u115))

;; Define minimum collateralization ratio (150%)
(define-constant min-collateral-ratio u150)

;; Define minimum and maximum mint amounts
(define-constant min-mint-amount u100000000) ;; 1 STX
(define-constant max-mint-amount u10000000000000) ;; 100,000 STX

;; Price expiration time in blocks
(define-constant price-expiration-blocks u144) ;; ~24 hours assuming 10-minute blocks

;; Protocol fee settings (basis points - 100 = 1%)
(define-data-var minting-fee uint u50) ;; 0.5% fee on minting
(define-data-var redemption-fee uint u25) ;; 0.25% fee on redemption
(define-data-var liquidation-penalty uint u500) ;; 5% penalty on liquidation

;; Protocol revenue tracking
(define-data-var total-protocol-fees uint u0)

;; Contract pause control
(define-data-var contract-paused bool false)

;; Governance control
(define-map authorized-governance 
  { governor: principal }
  { can-update-params: bool }
)

;; Oracle control
(define-map authorized-oracles
  { oracle: principal }
  { can-update-prices: bool }
)

;; Cooldown periods for operations (in blocks)
(define-data-var redemption-cooldown uint u10) ;; ~100 minutes

;; Define supported synthetic assets
(define-map supported-assets
  { asset-id: (string-ascii 10) }
  { 
    is-active: bool,
    decimals: uint
  }
)

;; Define price feed directly in this contract
(define-map asset-prices
  { asset-id: (string-ascii 10) }
  {
    price: uint,
    last-updated: uint,
    provider: principal
  }
)

;; Track user positions
(define-map user-positions
  { user: principal, asset-id: (string-ascii 10) }
  {
    collateral-amount: uint,
    synthetic-amount: uint,
    creation-block: uint,
    last-update-block: uint
  }
)

;; Keep track of total amounts
(define-map asset-totals
  { asset-id: (string-ascii 10) }
  {
    total-collateral: uint,
    total-synthetic: uint
  }
)

;; Contract governance functions

;; Add a governor
(define-public (add-governor (governor principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set authorized-governance
      { governor: governor }
      { can-update-params: true }
    )
    (ok true)
  )
)

;; Remove a governor
(define-public (remove-governor (governor principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-delete authorized-governance { governor: governor })
    (ok true)
  )
)

;; Add an oracle
(define-public (add-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set authorized-oracles
      { oracle: oracle }
      { can-update-prices: true }
    )
    (ok true)
  )
)

;; Remove an oracle
(define-public (remove-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-delete authorized-oracles { oracle: oracle })
    (ok true)
  )
)

;; Emergency pause contract
(define-public (set-pause-state (paused bool))
  (begin
    (asserts! (is-authorized-governor) err-governance-only)
    (var-set contract-paused paused)
    (ok paused)
  )
)

;; Update protocol fees
(define-public (update-protocol-fees (new-minting-fee uint) (new-redemption-fee uint) (new-liquidation-penalty uint))
  (begin
    (asserts! (is-authorized-governor) err-governance-only)
    ;; Validate fee ranges (max 5% for regular fees, max 10% for liquidation)
    (asserts! (and (<= new-minting-fee u500) (<= new-redemption-fee u500)) err-invalid-fee)
    (asserts! (<= new-liquidation-penalty u1000) err-invalid-fee)
    
    (var-set minting-fee new-minting-fee)
    (var-set redemption-fee new-redemption-fee)
    (var-set liquidation-penalty new-liquidation-penalty)
    (ok true)
  )
)

;; Update cooldown periods
(define-public (update-cooldown-period (new-redemption-cooldown uint))
  (begin
    (asserts! (is-authorized-governor) err-governance-only)
    (var-set redemption-cooldown new-redemption-cooldown)
    (ok true)
  )
)

;; Withdraw protocol fees
(define-public (withdraw-protocol-fees (recipient principal))
  (let
    (
      (fee-amount (var-get total-protocol-fees))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> fee-amount u0) err-insufficient-collateral)
    
    ;; Reset fees
    (var-set total-protocol-fees u0)
    
    ;; Transfer fees to recipient
    (try! (as-contract (stx-transfer? fee-amount (as-contract tx-sender) recipient)))
    
    (ok fee-amount)
  )
)

;; Initialize supported synthetic assets
(define-public (initialize-asset (asset-id (string-ascii 10)) (decimals uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set supported-assets
      { asset-id: asset-id }
      {
        is-active: true,
        decimals: decimals
      }
    )
    (map-set asset-totals
      { asset-id: asset-id }
      {
        total-collateral: u0,
        total-synthetic: u0
      }
    )
    (ok true)
  )
)

;; Update price feed (can be done by contract owner or authorized oracles)
(define-public (update-price (asset-id (string-ascii 10)) (price uint))
  (let
    (
      (asset (unwrap! (get-asset-info asset-id) err-invalid-asset))
      (current-price-data (default-to 
                            { price: u0, last-updated: u0, provider: contract-owner }
                            (map-get? asset-prices { asset-id: asset-id })))
    )
    ;; Check if oracle is authorized
    (asserts! (is-authorized-oracle) err-oracle-only)
    (asserts! (is-eq (get is-active asset) true) err-invalid-asset)
    
    ;; Set the new price
    (map-set asset-prices
      { asset-id: asset-id }
      {
        price: price,
        last-updated: block-height,
        provider: tx-sender
      }
    )
    
    (ok price)
  )
)

;; Get price from the internal price feed
(define-read-only (get-asset-price (asset-id (string-ascii 10)))
  (let
    (
      (price-data (unwrap! (map-get? asset-prices { asset-id: asset-id }) err-invalid-asset))
      (last-updated (get last-updated price-data))
      (price-age (- block-height last-updated))
    )
    ;; Check if price is fresh enough
    (asserts! (< price-age price-expiration-blocks) err-price-expired)
    
    (ok {
      price: (get price price-data),
      last-updated: last-updated
    })
  )
)

;; Helper to calculate fee
(define-read-only (calculate-fee (amount uint) (fee-rate uint))
  (/ (* amount fee-rate) u10000)
)

;; Create a new synthetic position
(define-public (mint-synthetic 
    (asset-id (string-ascii 10)) 
    (collateral-amount uint) 
    (synthetic-amount uint))
  (let
    (
      (asset (unwrap! (get-asset-info asset-id) err-invalid-asset))
      (price-result (unwrap! (get-asset-price asset-id) err-invalid-asset))
      (asset-price (get price price-result))
      (fee-amount (calculate-fee collateral-amount (var-get minting-fee)))
      (effective-collateral (- collateral-amount fee-amount))
      (collateral-value (* effective-collateral u100000000))
      (synthetic-value (* synthetic-amount asset-price))
      (collateral-ratio (/ (* collateral-value u100) synthetic-value))
      (user-key { user: tx-sender, asset-id: asset-id })
      (asset-key { asset-id: asset-id })
      (existing-totals (default-to { total-collateral: u0, total-synthetic: u0 } 
                      (map-get? asset-totals asset-key)))
      (existing-position (map-get? user-positions user-key))
    )
    ;; Check if contract is paused
    (asserts! (not (var-get contract-paused)) err-paused)
    
    ;; Check if synthetic position would be valid
    (asserts! (>= synthetic-amount min-mint-amount) err-minimum-mint)
    (asserts! (<= synthetic-amount max-mint-amount) err-maximum-mint)
    (asserts! (>= collateral-ratio min-collateral-ratio) err-insufficient-collateral)
    (asserts! (is-eq (get is-active asset) true) err-invalid-asset)
    
    ;; Transfer collateral from user to contract
    (try! (stx-transfer? collateral-amount tx-sender (as-contract tx-sender)))
    
    ;; Update protocol fees
    (var-set total-protocol-fees (+ (var-get total-protocol-fees) fee-amount))
    
    ;; Create or update position
    (match existing-position
      existing-pos ;; Update existing position
      (map-set user-positions
        user-key
        {
          collateral-amount: (+ (get collateral-amount existing-pos) effective-collateral),
          synthetic-amount: (+ (get synthetic-amount existing-pos) synthetic-amount),
          creation-block: (get creation-block existing-pos),
          last-update-block: block-height
        }
      )
      ;; Create new position
      (map-set user-positions
        user-key
        {
          collateral-amount: effective-collateral,
          synthetic-amount: synthetic-amount,
          creation-block: block-height,
          last-update-block: block-height
        }
      )
    )
    
    ;; Update asset totals
    (map-set asset-totals
      asset-key
      {
        total-collateral: (+ (get total-collateral existing-totals) effective-collateral),
        total-synthetic: (+ (get total-synthetic existing-totals) synthetic-amount)
      }
    )
    
    ;; Return success
    (ok synthetic-amount)
  )
)

;; Add collateral to an existing position
(define-public (add-collateral (asset-id (string-ascii 10)) (amount uint))
  (let
    (
      (user-key { user: tx-sender, asset-id: asset-id })
      (position (unwrap! (map-get? user-positions user-key) err-not-found))
      (asset-key { asset-id: asset-id })
      (existing-totals (default-to { total-collateral: u0, total-synthetic: u0 }
                      (map-get? asset-totals asset-key)))
      (new-collateral-amount (+ (get collateral-amount position) amount))
    )
    ;; Check if contract is paused
    (asserts! (not (var-get contract-paused)) err-paused)
    
    ;; Transfer additional collateral
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update position
    (map-set user-positions
      user-key
      {
        collateral-amount: new-collateral-amount,
        synthetic-amount: (get synthetic-amount position),
        creation-block: (get creation-block position),
        last-update-block: block-height
      }
    )
    
    ;; Update asset totals
    (map-set asset-totals
      asset-key
      {
        total-collateral: (+ (get total-collateral existing-totals) amount),
        total-synthetic: (get total-synthetic existing-totals)
      }
    )
    
    (ok new-collateral-amount)
  )
)

;; Redeem synthetic assets and reclaim collateral
(define-public (redeem-synthetic (asset-id (string-ascii 10)) (synthetic-amount uint))
  (let
    (
      (user-key { user: tx-sender, asset-id: asset-id })
      (position (unwrap! (map-get? user-positions user-key) err-not-found))
      (asset-key { asset-id: asset-id })
      (existing-totals (default-to { total-collateral: u0, total-synthetic: u0 }
                       (map-get? asset-totals asset-key)))
      (position-synthetic (get synthetic-amount position))
      (position-collateral (get collateral-amount position))
      (last-update (get last-update-block position))
      (blocks-since-update (- block-height last-update))
    )
    ;; Check if contract is paused
    (asserts! (not (var-get contract-paused)) err-paused)
    
    ;; Check redemption cooldown period
    (asserts! (>= blocks-since-update (var-get redemption-cooldown)) err-cooldown-period)
    
    ;; Check if user has enough synthetic assets
    (asserts! (<= synthetic-amount position-synthetic) err-insufficient-collateral)
    
    ;; Calculate collateral to return based on the proportion of synthetic being redeemed
    (let
      (
        (redemption-ratio (/ (* synthetic-amount u100000000) position-synthetic))
        (collateral-to-return (/ (* position-collateral redemption-ratio) u100000000))
        (fee-amount (calculate-fee collateral-to-return (var-get redemption-fee)))
        (net-collateral-return (- collateral-to-return fee-amount))
        (remaining-synthetic (- position-synthetic synthetic-amount))
        (remaining-collateral (- position-collateral collateral-to-return))
      )
      ;; Update protocol fees
      (var-set total-protocol-fees (+ (var-get total-protocol-fees) fee-amount))
      
      ;; If redeeming all, delete the position
      (if (is-eq remaining-synthetic u0)
        (begin
          (map-delete user-positions user-key)
          
          ;; Update asset totals
          (map-set asset-totals
            asset-key
            {
              total-collateral: (- (get total-collateral existing-totals) position-collateral),
              total-synthetic: (- (get total-synthetic existing-totals) position-synthetic)
            }
          )
        )
        (begin
          ;; Update position with remaining amounts
          (map-set user-positions
            user-key
            {
              collateral-amount: remaining-collateral,
              synthetic-amount: remaining-synthetic,
              creation-block: (get creation-block position),
              last-update-block: block-height
            }
          )
          
          ;; Update asset totals
          (map-set asset-totals
            asset-key
            {
              total-collateral: (- (get total-collateral existing-totals) collateral-to-return),
              total-synthetic: (- (get total-synthetic existing-totals) synthetic-amount)
            }
          )
        )
      )
      
      ;; Transfer collateral back to user
      (try! (as-contract (stx-transfer? net-collateral-return (as-contract tx-sender) tx-sender)))
      
      (ok {
        synthetic-redeemed: synthetic-amount,
        collateral-returned: net-collateral-return,
        fee-paid: fee-amount
      })
    )
  )
)

;; Get collateralization ratio helper function
(define-read-only (calculate-collateralization-ratio (collateral-amount uint) (synthetic-amount uint) (asset-price uint))
  (let
    (
      (collateral-value (* collateral-amount u100000000))
      (synthetic-value (* synthetic-amount asset-price))
    )
    (/ (* collateral-value u100) synthetic-value)
  )
)

;; Helper functions for internal authorization checks
(define-read-only (is-authorized-governor)
  (or 
    (is-eq tx-sender contract-owner)
    (is-some (map-get? authorized-governance { governor: tx-sender }))
  )
)

(define-read-only (is-authorized-oracle)
  (or 
    (is-eq tx-sender contract-owner)
    (is-some (map-get? authorized-oracles { oracle: tx-sender }))
  )
)

;; Read-only functions for UI
(define-read-only (get-position (user principal) (asset-id (string-ascii 10)))
  (map-get? user-positions { user: user, asset-id: asset-id })
)

;; Get position info for a user
(define-read-only (get-position-info (user principal) (asset-id (string-ascii 10)))
  (let
    (
      (position (unwrap! (map-get? user-positions { user: user, asset-id: asset-id }) err-not-found))
    )
    (ok {
      collateral-amount: (get collateral-amount position),
      synthetic-amount: (get synthetic-amount position),
      creation-block: (get creation-block position),
      last-update-block: (get last-update-block position)
    })
  )
)

;; Public function that can be called to check the collateralization ratio
(define-public (check-collateralization-ratio (user principal) (asset-id (string-ascii 10)))
  (let
    (
      (position (unwrap! (map-get? user-positions { user: user, asset-id: asset-id }) err-not-found))
      (price-result (unwrap! (get-asset-price asset-id) err-invalid-asset))
      (asset-price (get price price-result))
    )
    (ok (calculate-collateralization-ratio 
          (get collateral-amount position) 
          (get synthetic-amount position) 
          asset-price))
  )
)

(define-read-only (get-asset-info (asset-id (string-ascii 10)))
  (map-get? supported-assets { asset-id: asset-id })
)

(define-read-only (get-asset-stats (asset-id (string-ascii 10)))
  (map-get? asset-totals { asset-id: asset-id })
)

(define-read-only (get-current-price (asset-id (string-ascii 10)))
  (map-get? asset-prices { asset-id: asset-id })
)

;; Protocol info functions
(define-read-only (get-protocol-fees)
  (var-get total-protocol-fees)
)

(define-read-only (get-fee-rates)
  {
    minting-fee: (var-get minting-fee),
    redemption-fee: (var-get redemption-fee),
    liquidation-penalty: (var-get liquidation-penalty)
  }
)

(define-read-only (get-protocol-settings)
  {
    paused: (var-get contract-paused),
    min-collateral-ratio: min-collateral-ratio,
    redemption-cooldown: (var-get redemption-cooldown),
    price-expiration: price-expiration-blocks
  }
)