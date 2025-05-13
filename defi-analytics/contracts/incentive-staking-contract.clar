;; QuantStack Metrics Platform - Stage 1
;; Basic DeFi metrics with simple participation model

;; Base Constants
(define-constant admin-account tx-sender)
(define-constant ERROR-PERMISSION-DENIED (err u2001))
(define-constant ERROR-QUANTITY-INVALID (err u2003))
(define-constant ERROR-STX-BALANCE-LOW (err u2004))
(define-constant ERROR-UNDER-THRESHOLD (err u2007))
(define-constant ERROR-SYSTEM-HALTED (err u2008))

;; Platform Token Definition
(define-fungible-token METRICS-TOKEN)

;; System State Variables
(define-data-var system-halted bool false)

;; Participation Configuration
(define-data-var stx-reserve uint u0)
(define-data-var yield-baseline uint u500) ;; 5% base rate (100 = 1%)
(define-data-var entry-threshold uint u1000000) ;; Minimum participation amount

;; Enhanced Data Structures
(define-map ParticipantMetrics
    principal
    {
        stx-committed: uint,
        platform-tokens: uint,
        rank-category: uint,
        benefit-factor: uint,
        last-refresh: uint
    }
)

(define-map ParticipationDetails
    principal
    {
        quantity: uint,
        entry-block: uint,
        previous-claim: uint
    }
)

(define-map RankCategories
    uint  ;; rank category
    {
        entry-requirement: uint,
        benefit-multiplier: uint
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
                benefit-multiplier: u100      ;; 1x
            })
        (map-set RankCategories u2
            {
                entry-requirement: u5000000,  ;; 5M uSTX
                benefit-multiplier: u150      ;; 1.5x
            })
        (map-set RankCategories u3
            {
                entry-requirement: u10000000, ;; 10M uSTX
                benefit-multiplier: u200      ;; 2x
            })
        (ok true)
    )
)

;; Commit STX to the platform
(define-public (commit-stx (quantity uint))
    (let
        (
            (current-metrics (default-to 
                {
                    stx-committed: u0,
                    platform-tokens: u0,
                    rank-category: u0,
                    benefit-factor: u100,
                    last-refresh: u0
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
            )
            
            ;; Update participation details
            (map-set ParticipationDetails
                tx-sender
                {
                    quantity: quantity,
                    entry-block: block-height,
                    previous-claim: block-height
                }
            )
            
            ;; Update participant metrics with new rank data
            (map-set ParticipantMetrics
                tx-sender
                (merge current-metrics
                    {
                        stx-committed: new-total-commitment,
                        rank-category: (get rank-category rank-data),
                        benefit-factor: (get benefit-multiplier rank-data),
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

;; Withdraw STX from the platform
(define-public (withdraw-stx (quantity uint))
    (let
        (
            (current-metrics (default-to 
                {
                    stx-committed: u0,
                    platform-tokens: u0,
                    rank-category: u0,
                    benefit-factor: u100,
                    last-refresh: u0
                }
                (map-get? ParticipantMetrics tx-sender)))
            (current-committed (get stx-committed current-metrics))
        )
        (asserts! (not (var-get system-halted)) ERROR-SYSTEM-HALTED)
        (asserts! (<= quantity current-committed) ERROR-STX-BALANCE-LOW)
        
        ;; Transfer STX from contract
        (try! (as-contract (stx-transfer? quantity tx-sender tx-sender)))
        
        ;; Calculate new rank after withdrawal
        (let
            (
                (new-total-commitment (- current-committed quantity))
                (rank-data (evaluate-rank-category new-total-commitment))
            )
            
            ;; Update participant metrics with new rank data
            (map-set ParticipantMetrics
                tx-sender
                (merge current-metrics
                    {
                        stx-committed: new-total-commitment,
                        rank-category: (get rank-category rank-data),
                        benefit-factor: (get benefit-multiplier rank-data),
                        last-refresh: block-height
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
                    stx-committed: u0,
                    platform-tokens: u0,
                    rank-category: u0,
                    benefit-factor: u100,
                    last-refresh: u0
                }
                (map-get? ParticipantMetrics tx-sender)))
            (participation-details (default-to
                {
                    quantity: u0,
                    entry-block: u0,
                    previous-claim: u0
                }
                (map-get? ParticipationDetails tx-sender)))
            (blocks-since-claim (- block-height (get previous-claim participation-details)))
            (committed-amount (get stx-committed current-metrics))
            (benefit-factor (get benefit-factor current-metrics))
        )
        (asserts! (> committed-amount u0) ERROR-STX-BALANCE-LOW)
        
        ;; Calculate rewards
        (let
            (
                (base-reward (/ (* committed-amount blocks-since-claim (var-get yield-baseline)) u1000000))
                (adjusted-reward (/ (* base-reward benefit-factor) u100))
            )
            
            ;; Mint reward tokens
            (try! (ft-mint? METRICS-TOKEN adjusted-reward tx-sender))
            
            ;; Update participation details
            (map-set ParticipationDetails
                tx-sender
                (merge participation-details
                    {
                        previous-claim: block-height
                    }
                )
            )
            
            ;; Update participant metrics
            (map-set ParticipantMetrics
                tx-sender
                (merge current-metrics
                    {
                        platform-tokens: (+ (get platform-tokens current-metrics) adjusted-reward),
                        last-refresh: block-height
                    }
                )
            )
            
            (ok adjusted-reward)
        )
    )
)

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

;; Emergency Functions

;; Pause/halt the contract
(define-public (set-system-status (halted bool))
    (begin
        (asserts! (is-eq tx-sender admin-account) ERROR-PERMISSION-DENIED)
        (var-set system-halted halted)
        (ok halted)
    )
)