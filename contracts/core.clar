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

;; Define minimum collateralization ratio (150%)
(define-constant min-collateral-ratio u150)

;; Define minimum and maximum mint amounts
(define-constant min-mint-amount u100000000) ;; 1 STX
(define-constant max-mint-amount u10000000000000) ;; 100,000 STX

;; Price expiration time in blocks
(define-constant price-expiration-blocks u144) ;; ~24 hours assuming 10-minute blocks

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
    creation-block: uint
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

;; Update price feed (can only be done by contract owner or authorized providers)
(define-public (update-price (asset-id (string-ascii 10)) (price uint))
  (let
    (
      (asset (unwrap! (get-asset-info asset-id) err-invalid-asset))
      (current-price-data (default-to 
                            { price: u0, last-updated: u0, provider: contract-owner }
                            (map-get? asset-prices { asset-id: asset-id })))
    )
    ;; Only contract owner can update prices
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
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
      (collateral-value (* collateral-amount u100000000))
      (synthetic-value (* synthetic-amount asset-price))
      (collateral-ratio (/ (* collateral-value u100) synthetic-value))
      (user-key { user: tx-sender, asset-id: asset-id })
      (asset-key { asset-id: asset-id })
      (existing-totals (default-to { total-collateral: u0, total-synthetic: u0 } 
                      (map-get? asset-totals asset-key)))
    )
    ;; Check if synthetic position would be valid
    (asserts! (>= synthetic-amount min-mint-amount) err-minimum-mint)
    (asserts! (<= synthetic-amount max-mint-amount) err-maximum-mint)
    (asserts! (>= collateral-ratio min-collateral-ratio) err-insufficient-collateral)
    (asserts! (is-eq (get is-active asset) true) err-invalid-asset)
    
    ;; Transfer collateral from user to contract
    (try! (stx-transfer? collateral-amount tx-sender (as-contract tx-sender)))
    
    ;; Create or update position
    (map-set user-positions
      user-key
      {
        collateral-amount: collateral-amount,
        synthetic-amount: synthetic-amount,
        creation-block: block-height
      }
    )
    
    ;; Update asset totals
    (map-set asset-totals
      asset-key
      {
        total-collateral: (+ (get total-collateral existing-totals) collateral-amount),
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
    ;; Transfer additional collateral
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update position
    (map-set user-positions
      user-key
      {
        collateral-amount: new-collateral-amount,
        synthetic-amount: (get synthetic-amount position),
        creation-block: (get creation-block position)
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

;; Redeem synthetic position and get collateral back
(define-public (redeem-synthetic (asset-id (string-ascii 10)) (amount uint))
  (let
    (
      (user-key { user: tx-sender, asset-id: asset-id })
      (position (unwrap! (map-get? user-positions user-key) err-not-found))
      (asset-key { asset-id: asset-id })
      (existing-totals (default-to { total-collateral: u0, total-synthetic: u0 }
                      (map-get? asset-totals asset-key)))
      (position-synthetic (get synthetic-amount position))
      (position-collateral (get collateral-amount position))
      (collateral-to-return (/ (* position-collateral amount) position-synthetic))
      (new-synthetic-amount (- position-synthetic amount))
      (new-collateral-amount (- position-collateral collateral-to-return))
    )
    ;; Verify user has enough synthetic assets
    (asserts! (<= amount position-synthetic) err-insufficient-collateral)
    
    ;; Handle full redemption vs partial redemption
    (if (is-eq new-synthetic-amount u0)
      ;; If fully redeeming
      (begin
        ;; Update asset totals before deleting the position
        (map-set asset-totals
          asset-key
          {
            total-collateral: (- (get total-collateral existing-totals) position-collateral),
            total-synthetic: (- (get total-synthetic existing-totals) position-synthetic)
          }
        )
        
        ;; Delete the position
        (map-delete user-positions user-key)
        
        ;; Return full collateral
        (as-contract (stx-transfer? position-collateral (as-contract tx-sender) tx-sender))
        
        ;; Return success with collateral amount
        (ok position-collateral)
      )
      ;; If partially redeeming
      (begin
        ;; Update the position
        (map-set user-positions
          user-key
          {
            collateral-amount: new-collateral-amount,
            synthetic-amount: new-synthetic-amount,
            creation-block: (get creation-block position)
          }
        )
        
        ;; Update asset totals
        (map-set asset-totals
          asset-key
          {
            total-collateral: (- (get total-collateral existing-totals) collateral-to-return),
            total-synthetic: (- (get total-synthetic existing-totals) amount)
          }
        )
        
        ;; Return partial collateral
        (as-contract (stx-transfer? collateral-to-return (as-contract tx-sender) tx-sender))
        
        ;; Return success with collateral amount
        (ok collateral-to-return)
      )
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

;; Liquidate an unsafe position
(define-public (liquidate-position (user principal) (asset-id (string-ascii 10)))
  (let
    (
      (user-key { user: user, asset-id: asset-id })
      (position (unwrap! (map-get? user-positions user-key) err-not-found))
      (price-result (unwrap! (get-asset-price asset-id) err-invalid-asset))
      (asset-price (get price price-result))
      (current-ratio (calculate-collateralization-ratio 
                        (get collateral-amount position) 
                        (get synthetic-amount position) 
                        asset-price))
      (asset-key { asset-id: asset-id })
      (existing-totals (default-to { total-collateral: u0, total-synthetic: u0 }
                      (map-get? asset-totals asset-key)))
      (liquidation-reward (/ (* (get collateral-amount position) u5) u100)) ;; 5% reward
      (remaining-collateral (- (get collateral-amount position) liquidation-reward))
    )
    ;; Verify position is unsafe
    (asserts! (< current-ratio min-collateral-ratio) err-unsafe-ratio)
    
    ;; Delete the position
    (map-delete user-positions user-key)
    
    ;; Update asset totals
    (map-set asset-totals
      asset-key
      {
        total-collateral: (- (get total-collateral existing-totals) (get collateral-amount position)),
        total-synthetic: (- (get total-synthetic existing-totals) (get synthetic-amount position))
      }
    )
    
    ;; Send liquidation reward to liquidator
    (try! (as-contract (stx-transfer? liquidation-reward (as-contract tx-sender) tx-sender)))
    
    ;; Return remaining collateral to position owner
    (try! (as-contract (stx-transfer? remaining-collateral (as-contract tx-sender) user)))
    
    (ok true)
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
      creation-block: (get creation-block position)
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