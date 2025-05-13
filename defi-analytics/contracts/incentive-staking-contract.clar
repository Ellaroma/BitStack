;; QuantStack Metrics Platform - Stage 2
;; Enhanced DeFi metrics with time locks and expanded features

;; Base Constants
(define-constant admin-account tx-sender)
(define-constant ERROR-PERMISSION-DENIED (err u2001))
(define-constant ERROR-PROTOCOL-MISMATCH (err u2002))
(define-constant ERROR-QUANTITY-INVALID (err u2003))
(define-constant ERROR-STX-BALANCE-LOW (err u2004))
(define-constant ERROR-WAITING-PERIOD (err u2005))
(define-constant ERROR-NO-PARTICIPATION (err u2006))
(define-constant ERROR-UNDER-THRESHOLD (err u2007))
(define-constant ERROR-SYSTEM-HALTED (err u2008))

;; Platform Token Definition
(define-fungible-token METRICS-TOKEN)

;; System State Variables
(define-data-var system-halted bool false)
(define-data-var security-lockdown bool false)

;; Participation Configuration
(define-data-var stx-reserve uint u0)
(define-data-var yield-baseline uint u500) ;; 5% base rate (100 = 1%)
(define-data-var duration-incentive uint u100) ;; 1% extra for extended participation
(define-data-var entry-threshold uint u1000000) ;; Minimum participation amount
(define-data-var waiting-blocks uint u1440) ;; 24 hour waiting period in blocks

;; Enhanced Data Structures
(define-map ParticipantMetrics
    principal
    {
        committed-assets: uint,
        financial-obligations: uint,
        security-ratio: uint,
        last-refresh: uint,
        stx-committed: uint,
        platform-tokens: uint,
        rank-category: uint,
        benefit-factor: uint
    }
)

(define-map ParticipationDetails
    principal
    {
        quantity: uint,
        entry-block: uint,
        previous-claim: uint,
        commitment-duration: uint,
        exit-timer: (optional uint),
        pending-benefits: uint
    }
)

(define-map RankCategories
    uint  ;; rank category
    {
        entry-requirement: uint,
        benefit-multiplier: uint,
        access-privileges: (list 5 bool)
    }
)

;; Protocol Configuration
(define-map SupportedProtocols
    (string-ascii 20)
    {
        active: bool,
        risk-factor: uint,
        yield-rate: uint
    }
)

;; Contract Initialization
(define-public (setup-platform)
    (begin
        (asserts! (is-eq tx-sender admin-account) ERROR-PERMISSION-DENIED)
        
        ;; Configure rank categories
        (map-set RankCategories u1 
            {
                entry-requirement: u1000000,  ;; 1M uSTX
                benefit-multiplier: u100,     ;; 1x
                access-privileges: (list true false false false false)
            })
        (map-set RankCategories u2
            {
                entry-requirement: u5000000,  ;; 5M uSTX
                benefit-multiplier: u150,     ;; 1.5x
                access-privileges: (list true true true false false)
            })
        (map-set RankCategories u3
            {
                entry-requirement: u10000000, ;; 10M uSTX
                benefit-multiplier: u200,     ;; 2x
                access-privileges: (list true true true true true)
            })
            
        ;; Initialize protocols
        (map-set SupportedProtocols "bitcoin"
            {
                active: true,
                risk-factor: u200,
                yield-rate: u300
            }
        )
        (map-set SupportedProtocols "ethereum"
            {
                active: true,
                risk-factor: u250,
                yield-rate: u400
            }
        )
        
        (ok true)
    )
)

;; Commit STX with optional time lock
(define-public (commit-stx (quantity uint) (lock-duration uint))
    (let
        (
            (current-metrics (default-to 
                {
                    committed-assets: u0,
                    financial-obligations: u0,
                    security-ratio: u0,
                    last-refresh: u0,
                    stx-committed: u0,
                    platform-tokens: u0,
                    rank-category: u0,
                    benefit-factor: u100
                }
                (map-get? ParticipantMetrics tx-sender)))
        )
        (asserts! (not (var-get system-halted)) ERROR-SYSTEM-HALTED)
        (asserts! (>= quantity (var-get entry-threshold)) ERROR-UNDER-THRESHOLD)
        
        ;; Transfer STX to contract
        (try! (stx-transfer? quantity tx-sender (as-contract tx-sender)))
        
        ;; Calculate rank and multiplier
        (let
            (
                (new-total-commitment (+ (get stx-committed current-metrics) quantity))
                (rank-data (evaluate-rank-category new-total-commitment))
                (duration-modifier (calculate-duration-modifier lock-duration))
                (security-calculation (calculate-security-ratio new-total-commitment u0))
            )
            
            ;; Update participation details
            (map-set ParticipationDetails
                tx-sender
                {
                    quantity: quantity,
                    entry-block: block-height,
                    previous-claim: block-height,
                    commitment-duration: lock-duration,
                    exit-timer: none,
                    pending-benefits: u0
                }
            )
            
            ;; Update participant metrics with new rank data
            (map-set ParticipantMetrics
                tx-sender
                (merge current-metrics
                    {
                        committed-assets: new-total-commitment,
                        stx-committed: new-total-commitment,
                        security-ratio: security-calculation,
                        rank-category: (get rank-category rank-data),
                        benefit-factor: (* (get benefit-multiplier rank-data) duration-modifier),
                        last-refresh: block-height
                    }
                )
            )
            
            ;; Update STX reserve
            (var-set stx-reserve (+ (var-get stx-reserve) quantity))
            (ok true)
        )
    )
)

;; Initiate withdrawal process
(define-public (start-withdrawal (quantity uint))
    (let
        (
            (current-metrics (default-to 
                {
                    committed-assets: u0,
                    financial-obligations: u0,
                    security-ratio: u0,
                    last-refresh: u0,
                    stx-committed: u0,
                    platform-tokens: u0,
                    rank-category: u0,
                    benefit-factor: u100
                }
                (map-get? ParticipantMetrics tx-sender)))
            (participation-details (default-to
                {
                    quantity: u0,
                    entry-block: u0,
                    previous-claim: u0,
                    commitment-duration: u0,
                    exit-timer: none,
                    pending-benefits: u0
                }
                (map-get? ParticipationDetails tx-sender)))
            (current-committed (get stx-committed current-metrics))
            (active-lock (get commitment-duration participation-details))
        )
        (asserts! (not (var-get system-halted)) ERROR-SYSTEM-HALTED)
        (asserts! (<= quantity current-committed) ERROR-STX-BALANCE-LOW)
        
        ;; Check if lock period is over
        (asserts! (<= active-lock block-height) ERROR-WAITING-PERIOD)
        
        ;; Set exit timer
        (map-set ParticipationDetails
            tx-sender
            (merge participation-details
                {
                    exit-timer: (some block-height)
                }
            )
        )
        
        (ok block-height)
    )
)

;; Complete withdrawal after waiting period
(define-public (complete-withdrawal (quantity uint))
    (let
        (
            (current-metrics (default-to 
                {
                    committed-assets: u0,
                    financial-obligations: u0,
                    security-ratio: u0,
                    last-refresh: u0,
                    stx-committed: u0,
                    platform-tokens: u0,
                    rank-category: u0,
                    benefit-factor: u100
                }
                (map-get? ParticipantMetrics tx-sender)))
            (participation-details (default-to
                {
                    quantity: u0,
                    entry-block: u0,
                    previous-claim: u0,
                    commitment-duration: u0,
                    exit-timer: none,
                    pending-benefits: u0
                }
                (map-get? ParticipationDetails tx-sender)))
            (current-committed (get stx-committed current-metrics))
            (exit-time (get exit-timer participation-details))
        )
        (asserts! (not (var-get system-halted)) ERROR-SYSTEM-HALTED)
        (asserts! (<= quantity current-committed) ERROR-STX-BALANCE-LOW)
        (asserts! (is-some exit-time) ERROR-NO-PARTICIPATION)
        
        ;; Check if waiting period is over
        (asserts! (>= block-height (+ (default-to u0 exit-time) (var-get waiting-blocks))) ERROR-WAITING-PERIOD)
        
        ;; Transfer STX from contract
        (try! (as-contract (stx-transfer? quantity tx-sender tx-sender)))
        
        ;; Calculate new rank after withdrawal
        (let
            (
                (new-total-commitment (- current-committed quantity))
                (rank-data (evaluate-rank-category new-total-commitment))
                (security-calculation (calculate-security-ratio new-total-commitment (get financial-obligations current-metrics)))
            )
            
            ;; Update participant metrics with new rank data
            (map-set ParticipantMetrics
                tx-sender
                (merge current-metrics
                    {
                        committed-assets: new-total-commitment,
                        stx-committed: new-total-commitment,
                        security-ratio: security-calculation,
                        rank-category: (get rank-category rank-data),
                        benefit-factor: (get benefit-multiplier rank-data),
                        last-refresh: block-height
                    }
                )
            )
            
            ;; Reset exit timer
            (map-set ParticipationDetails
                tx-sender
                (merge participation-details
                    {
                        exit-timer: none
                    }
                )
            )
            
            ;; Update STX reserve
            (var-set stx-reserve (- (var-get stx-reserve) quantity))
            (ok true)
        )
    )
)

;; Claim rewards based on commitment
(define-public (claim-rewards)
    (let
        (
            (current-metrics (default-to 
                {
                    committed-assets: u0,
                    financial-obligations: u0,
                    security-ratio: u0,
                    last-refresh: u0,
                    stx-committed: u0,
                    platform-tokens: u0,
                    rank-category: u0,
                    benefit-factor: u100
                }
                (map-get? ParticipantMetrics tx-sender)))
            (participation-details (default-to
                {
                    quantity: u0,
                    entry-block: u0,
                    previous-claim: u0,
                    commitment-duration: u0,
                    exit-timer: none,
                    pending-benefits: u0
                }
                (map-get? ParticipationDetails tx-sender)))
            (blocks-since-claim (- block-height (get previous-claim participation-details)))
            (committed-amount (get stx-committed current-metrics))
            (benefit-factor (get benefit-factor current-metrics))
            (pending (get pending-benefits participation-details))
        )
        (asserts! (> committed-amount u0) ERROR-STX-BALANCE-LOW)
        
        ;; Calculate rewards
        (let
            (
                (base-reward (/ (* committed-amount blocks-since-claim (var-get yield-baseline)) u1000000))
                (adjusted-reward (/ (* base-reward benefit-factor) u100))
                (total-rewards (+ adjusted-reward pending))
            )
            
            ;; Mint reward tokens
            (try! (ft-mint? METRICS-TOKEN total-rewards tx-sender))
            
            ;; Update participation details
            (map-set ParticipationDetails
                tx-sender
                (merge participation-details
                    {
                        previous-claim: block-height,
                        pending-benefits: u0
                    }
                )
            )
            
            ;; Update participant metrics
            (map-set ParticipantMetrics
                tx-sender
                (merge current-metrics
                    {
                        platform-tokens: (+ (get platform-tokens current-metrics) total-rewards),
                        last-refresh: block-height
                    }
                )
            )
            
            (ok total-rewards)
        )
    )
)

;; Register financial position with a protocol
(define-public (register-position (protocol-name (string-ascii 20)) (collateral uint) (debt uint))
    (let
        (
            (current-metrics (default-to 
                {
                    committed-assets: u0,
                    financial-obligations: u0,
                    security-ratio: u0,
                    last-refresh: u0,
                    stx-committed: u0,
                    platform-tokens: u0,
                    rank-category: u0,
                    benefit-factor: u100
                }
                (map-get? ParticipantMetrics tx-sender)))
            (protocol-info (map-get? SupportedProtocols protocol-name))
        )
        (asserts! (not (var-get system-halted)) ERROR-SYSTEM-HALTED)
        (asserts! (is-some protocol-info) ERROR-PROTOCOL-MISMATCH)
        (asserts! (get active (unwrap-panic protocol-info)) ERROR-PROTOCOL-MISMATCH)
        
        ;; Update financial metrics
        (let
            (
                (new-obligations (+ (get financial-obligations current-metrics) debt))
                (security-calculation (calculate-security-ratio (get committed-assets current-metrics) new-obligations))
            )
            
            ;; Update participant metrics
            (map-set ParticipantMetrics
                tx-sender
                (merge current-metrics
                    {
                        financial-obligations: new-obligations,
                        security-ratio: security-calculation,
                        last-refresh: block-height
                    }
                )
            )
            
            (ok security-calculation)
        )
    )
)

;; Helper Functions

;; Determine rank category based on commitment amount
(define-private (evaluate-rank-category (commitment-amount uint))
    (if (>= commitment-amount u10000000)
        {rank-category: u3, benefit-multiplier: u200}
        (if (>= commitment-amount u5000000)
            {rank-category: u2, benefit-multiplier: u150}
            {rank-category: u1, benefit-multiplier: u100}
        )
    )
)

;; Calculate duration modifier based on lock period
(define-private (calculate-duration-modifier (lock-duration uint))
    (if (>= lock-duration u8640)     ;; 2 months
        u150                         ;; 1.5x multiplier
        (if (>= lock-duration u4320) ;; 1 month
            u125                     ;; 1.25x multiplier
            u100                     ;; 1x multiplier (no lock)
        )
    )
)

;; Calculate security ratio
(define-private (calculate-security-ratio (assets uint) (obligations uint))
    (if (is-eq obligations u0)
        u10000  ;; Max ratio if no obligations
        (/ (* assets u10000) obligations)
    )
)

;; Emergency Functions

;; Pause/halt the contract
(define-public (set-system-status (halted bool))
    (begin
        (asserts! (is-eq tx-sender admin-account) ERROR-PERMISSION-DENIED)
        (var-set system-halted halted)
        (ok halted)
    )
)

;; Enable security lockdown
(define-public (set-security-lockdown (enabled bool))
    (begin
        (asserts! (is-eq tx-sender admin-account) ERROR-PERMISSION-DENIED)
        (var-set security-lockdown enabled)
        (ok enabled)
    )
)

;; Admin function to update protocol settings
(define-public (update-protocol-settings 
    (protocol-name (string-ascii 20)) 
    (active bool) 
    (risk-factor uint) 
    (yield-rate uint))
    (begin
        (asserts! (is-eq tx-sender admin-account) ERROR-PERMISSION-DENIED)
        (map-set SupportedProtocols protocol-name
            {
                active: active,
                risk-factor: risk-factor,
                yield-rate: yield-rate
            }
        )
        (ok true)
    )
)