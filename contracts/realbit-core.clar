;; =======================================================
;; RealBit Core Contract
;; =======================================================

;; This contract manages the tokenization, ownership, and trading of 
;; fractional real estate assets on the RealBit platform. It handles
;; property registration, token minting, ownership tracking, income
;; distribution, and governance for tokenized real estate properties.
;; =======================================================

;; =======================================================
;; Error Codes
;; =======================================================
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-PROPERTY-EXISTS (err u101))
(define-constant ERR-PROPERTY-NOT-FOUND (err u102))
(define-constant ERR-INSUFFICIENT-TOKENS (err u103))
(define-constant ERR-INVALID-AMOUNT (err u104))
(define-constant ERR-NOT-VERIFIED (err u105))
(define-constant ERR-TRANSFER-FAILED (err u106))
(define-constant ERR-MIN-HOLDING-PERIOD (err u107))
(define-constant ERR-INVALID-PROPERTY-ID (err u108))
(define-constant ERR-VOTING-CLOSED (err u109))
(define-constant ERR-ALREADY-VOTED (err u110))
(define-constant ERR-INSUFFICIENT-STAKE (err u111))
(define-constant ERR-MAX-SUPPLY-REACHED (err u112))
(define-constant ERR-DISABLED (err u113))

;; =======================================================
;; Constants
;; =======================================================
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-HOLDING-PERIOD u14) ;; 14-day minimum holding period (in blocks)
(define-constant MIN-VOTING-STAKE u50000000) ;; 5% of tokens required to create a vote (assuming 1B token max)
(define-constant VOTE-DURATION u1440) ;; approximately 10 days in blocks
(define-constant TOKEN-DECIMALS u6) ;; 6 decimal places for tokens
(define-constant DEFAULT-TOKEN-PRECISION (pow u10 TOKEN-DECIMALS))

;; =======================================================
;; Data Maps and Variables
;; =======================================================

;; Tracks verified property owners
(define-map verified-owners principal bool)

;; Contract operational state
(define-data-var contract-enabled bool true)

;; Property details mapping
(define-map properties 
    { property-id: uint }
    {
        owner: principal,
        location: (string-ascii 256),
        valuation: uint,
        annual-income: uint,
        total-supply: uint,
        tokens-minted: uint,
        creation-block: uint,
        active: bool
    }
)

;; Property token balances - tracks ownership of each property
(define-map token-balances 
    { property-id: uint, owner: principal } 
    { balance: uint, acquired-at-block: uint }
)

;; Governance proposal mapping
(define-map governance-proposals
    { property-id: uint, proposal-id: uint }
    {
        proposer: principal,
        title: (string-ascii 64),
        description: (string-ascii 256),
        start-block: uint,
        end-block: uint,
        votes-for: uint,
        votes-against: uint,
        executed: bool
    }
)

;; Tracks votes on proposals to prevent double voting
(define-map proposal-votes
    { property-id: uint, proposal-id: uint, voter: principal }
    { voted: bool, vote: bool }
)

;; Income distribution tracking
(define-map income-distributions
    { property-id: uint, distribution-id: uint }
    {
        amount: uint,
        block-height: uint,
        distributed: bool
    }
)

;; Track property-id counter
(define-data-var next-property-id uint u1)

;; Track proposal-id counter for each property
(define-map next-proposal-id uint uint)

;; Track distribution-id counter for each property
(define-map next-distribution-id uint uint)

;; =======================================================
;; Private Functions
;; =======================================================

;; Check that caller is contract owner
(define-private (is-contract-owner)
    (is-eq tx-sender CONTRACT-OWNER)
)

;; Check if contract is enabled
(define-private (is-contract-enabled)
    (var-get contract-enabled)
)

;; Check if principal is a verified property owner
(define-private (is-verified-owner (owner principal))
    (default-to false (map-get? verified-owners owner))
)

;; Get the property details
(define-private (get-property (property-id uint))
    (map-get? properties { property-id: property-id })
)

;; Get a user's token balance for a specific property
(define-private (get-token-balance (property-id uint) (owner principal))
    (default-to 
        { balance: u0, acquired-at-block: u0 } 
        (map-get? token-balances { property-id: property-id, owner: owner })
    )
)

;; Check if a property exists and is active
(define-private (is-active-property (property-id uint))
    (match (get-property property-id)
        property (get active property)
        false
    )
)

;; Check if user has sufficient tokens for a property
(define-private (has-sufficient-tokens (property-id uint) (owner principal) (amount uint))
    (let ((balance (get balance (get-token-balance property-id owner))))
        (>= balance amount)
    )
)

;; Check if tokens meet the minimum holding period requirement
(define-private (meets-holding-period (property-id uint) (owner principal) (amount uint))
    (let (
        (token-data (get-token-balance property-id owner))
        (current-block block-height)
    )
        (>= (- current-block (get acquired-at-block token-data)) MIN-HOLDING-PERIOD)
    )
)

;; =======================================================
;; Read-Only Functions
;; =======================================================

;; Get property details
(define-read-only (get-property-details (property-id uint))
    (match (get-property property-id)
        property (ok property)
        (err ERR-PROPERTY-NOT-FOUND)
    )
)

;; Get user's token balance for a property
(define-read-only (get-user-balance (property-id uint) (user principal))
    (ok (get balance (get-token-balance property-id user)))
)

;; Get governance proposal details
(define-read-only (get-proposal (property-id uint) (proposal-id uint))
    (match (map-get? governance-proposals { property-id: property-id, proposal-id: proposal-id })
        proposal (ok proposal)
        (err ERR-PROPERTY-NOT-FOUND)
    )
)

;; Check if user has voted on a proposal
(define-read-only (has-voted (property-id uint) (proposal-id uint) (voter principal))
    (match (map-get? proposal-votes { property-id: property-id, proposal-id: proposal-id, voter: voter })
        vote-info (ok (get voted vote-info))
        (ok false)
    )
)

;; Calculate user's ownership percentage for a property
(define-read-only (get-ownership-percentage (property-id uint) (owner principal))
    (match (get-property property-id)
        property 
        (let (
            (user-balance (get balance (get-token-balance property-id owner)))
            (total-supply (get total-supply property))
        )
            (if (is-eq total-supply u0)
                (ok u0)
                (ok (/ (* user-balance u100) total-supply))
            )
        )
        (err ERR-PROPERTY-NOT-FOUND)
    )
)

;; =======================================================
;; Public Functions
;; =======================================================

;; Set contract enabled/disabled status (owner only)
(define-public (set-contract-enabled (enabled bool))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (ok (var-set contract-enabled enabled))
    )
)

;; Add a verified property owner
(define-public (add-verified-owner (owner principal))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (ok (map-set verified-owners owner true))
    )
)

;; Remove a verified property owner
(define-public (remove-verified-owner (owner principal))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (ok (map-delete verified-owners owner))
    )
)

;; Register a new property
(define-public (register-property 
    (location (string-ascii 256))
    (valuation uint)
    (annual-income uint)
    (total-supply uint)
)
    (let ((property-id (var-get next-property-id)))
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (asserts! (is-verified-owner tx-sender) ERR-NOT-VERIFIED)
        (asserts! (> total-supply u0) ERR-INVALID-AMOUNT)
        
        ;; Create the new property
        (map-set properties 
            { property-id: property-id }
            {
                owner: tx-sender,
                location: location,
                valuation: valuation,
                annual-income: annual-income,
                total-supply: total-supply,
                tokens-minted: u0,
                creation-block: block-height,
                active: true
            }
        )
        
        ;; Initialize counters for this property
        (map-set next-proposal-id property-id u1)
        (map-set next-distribution-id property-id u1)
        
        ;; Increment property ID for next registration
        (var-set next-property-id (+ property-id u1))
        
        (ok property-id)
    )
)

;; Mint property tokens to a user (only property owner can mint)
(define-public (mint-property-tokens (property-id uint) (recipient principal) (amount uint))
    (let (
        (property (unwrap! (get-property-details property-id) ERR-PROPERTY-NOT-FOUND))
        (current-minted (get tokens-minted property))
        (total-supply (get total-supply property))
    )
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (asserts! (is-eq tx-sender (get owner property)) ERR-NOT-AUTHORIZED)
        (asserts! (is-active-property property-id) ERR-PROPERTY-NOT-FOUND)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (<= (+ current-minted amount) total-supply) ERR-MAX-SUPPLY-REACHED)
        
        ;; Update tokens minted for the property
        (map-set properties 
            { property-id: property-id }
            (merge property { tokens-minted: (+ current-minted amount) })
        )
        
        ;; Update recipient's token balance
        (let (
            (recipient-balance (get-token-balance property-id recipient))
            (new-balance (+ (get balance recipient-balance) amount))
        )
            (map-set token-balances 
                { property-id: property-id, owner: recipient }
                { balance: new-balance, acquired-at-block: block-height }
            )
            
            (ok new-balance)
        )
    )
)

;; Transfer property tokens to another user
(define-public (transfer-tokens (property-id uint) (recipient principal) (amount uint))
    (let (
        (sender-balance (get-token-balance property-id tx-sender))
    )
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (asserts! (is-active-property property-id) ERR-PROPERTY-NOT-FOUND)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (has-sufficient-tokens property-id tx-sender amount) ERR-INSUFFICIENT-TOKENS)
        (asserts! (meets-holding-period property-id tx-sender amount) ERR-MIN-HOLDING-PERIOD)
        (asserts! (not (is-eq tx-sender recipient)) ERR-TRANSFER-FAILED)
        
        ;; Update sender's balance
        (map-set token-balances 
            { property-id: property-id, owner: tx-sender }
            { 
                balance: (- (get balance sender-balance) amount), 
                acquired-at-block: (get acquired-at-block sender-balance) 
            }
        )
        
        ;; Update recipient's balance
        (let (
            (recipient-balance (get-token-balance property-id recipient))
            (new-balance (+ (get balance recipient-balance) amount))
        )
            (map-set token-balances 
                { property-id: property-id, owner: recipient }
                { balance: new-balance, acquired-at-block: block-height }
            )
            
            (ok new-balance)
        )
    )
)

;; Create a new governance proposal for a property
(define-public (create-proposal 
    (property-id uint) 
    (title (string-ascii 64)) 
    (description (string-ascii 256))
)
    (let (
        (property (unwrap! (get-property-details property-id) ERR-PROPERTY-NOT-FOUND))
        (proposer-balance (get balance (get-token-balance property-id tx-sender)))
        (total-supply (get total-supply property))
        (proposal-id (default-to u1 (map-get? next-proposal-id property-id)))
    )
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (asserts! (is-active-property property-id) ERR-PROPERTY-NOT-FOUND)
        
        ;; Check if proposer has minimum required stake (5%)
        (asserts! (>= proposer-balance MIN-VOTING-STAKE) ERR-INSUFFICIENT-STAKE)
        
        ;; Create the proposal
        (map-set governance-proposals
            { property-id: property-id, proposal-id: proposal-id }
            {
                proposer: tx-sender,
                title: title,
                description: description,
                start-block: block-height,
                end-block: (+ block-height VOTE-DURATION),
                votes-for: u0,
                votes-against: u0,
                executed: false
            }
        )
        
        ;; Increment proposal counter
        (map-set next-proposal-id property-id (+ proposal-id u1))
        
        (ok proposal-id)
    )
)

;; Vote on a governance proposal
(define-public (vote-on-proposal (property-id uint) (proposal-id uint) (vote-for bool))
    (let (
        (proposal (unwrap! (map-get? governance-proposals { property-id: property-id, proposal-id: proposal-id }) ERR-PROPERTY-NOT-FOUND))
        (voter-balance (get balance (get-token-balance property-id tx-sender)))
    )
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (asserts! (is-active-property property-id) ERR-PROPERTY-NOT-FOUND)
        (asserts! (>= block-height (get start-block proposal)) ERR-NOT-AUTHORIZED)
        (asserts! (<= block-height (get end-block proposal)) ERR-VOTING-CLOSED)
        (asserts! (not (get executed proposal)) ERR-VOTING-CLOSED)
        
        ;; Check if user has already voted
        (asserts! (not (default-to false (get voted (default-to { voted: false, vote: false } (map-get? proposal-votes { property-id: property-id, proposal-id: proposal-id, voter: tx-sender }))))) ERR-ALREADY-VOTED)
        
        ;; Record the vote
        (map-set proposal-votes
            { property-id: property-id, proposal-id: proposal-id, voter: tx-sender }
            { voted: true, vote: vote-for }
        )
        
        ;; Update vote counts based on token balance (weighted voting)
        (if vote-for
            (map-set governance-proposals
                { property-id: property-id, proposal-id: proposal-id }
                (merge proposal { votes-for: (+ (get votes-for proposal) voter-balance) })
            )
            (map-set governance-proposals
                { property-id: property-id, proposal-id: proposal-id }
                (merge proposal { votes-against: (+ (get votes-against proposal) voter-balance) })
            )
        )
        
        (ok true)
    )
)

;; Execute a governance proposal after voting period ends
(define-public (execute-proposal (property-id uint) (proposal-id uint))
    (let (
        (proposal (unwrap! (map-get? governance-proposals { property-id: property-id, proposal-id: proposal-id }) ERR-PROPERTY-NOT-FOUND))
        (property (unwrap! (get-property-details property-id) ERR-PROPERTY-NOT-FOUND))
    )
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (asserts! (is-active-property property-id) ERR-PROPERTY-NOT-FOUND)
        (asserts! (>= block-height (get end-block proposal)) ERR-VOTING-CLOSED)
        (asserts! (not (get executed proposal)) ERR-ALREADY-VOTED)
        
        ;; Only property owner or the proposal creator can execute the result
        (asserts! (or (is-eq tx-sender (get owner property)) (is-eq tx-sender (get proposer proposal))) ERR-NOT-AUTHORIZED)
        
        ;; Mark proposal as executed
        (map-set governance-proposals
            { property-id: property-id, proposal-id: proposal-id }
            (merge proposal { executed: true })
        )
        
        ;; Return the result of the vote
        (ok (> (get votes-for proposal) (get votes-against proposal)))
    )
)

;; Register income distribution for a property
(define-public (register-income-distribution (property-id uint) (amount uint))
    (let (
        (property (unwrap! (get-property-details property-id) ERR-PROPERTY-NOT-FOUND))
        (distribution-id (default-to u1 (map-get? next-distribution-id property-id)))
    )
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (asserts! (is-active-property property-id) ERR-PROPERTY-NOT-FOUND)
        (asserts! (is-eq tx-sender (get owner property)) ERR-NOT-AUTHORIZED)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        
        ;; Register the distribution
        (map-set income-distributions
            { property-id: property-id, distribution-id: distribution-id }
            {
                amount: amount,
                block-height: block-height,
                distributed: false
            }
        )
        
        ;; Increment distribution counter
        (map-set next-distribution-id property-id (+ distribution-id u1))
        
        (ok distribution-id)
    )
)

;; Deactivate a property (can only be done by the property owner)
(define-public (deactivate-property (property-id uint))
    (let (
        (property (unwrap! (get-property-details property-id) ERR-PROPERTY-NOT-FOUND))
    )
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (asserts! (is-eq tx-sender (get owner property)) ERR-NOT-AUTHORIZED)
        
        ;; Update property status to inactive
        (map-set properties 
            { property-id: property-id }
            (merge property { active: false })
        )
        
        (ok true)
    )
)

;; Reactivate a property (can only be done by the property owner)
(define-public (reactivate-property (property-id uint))
    (let (
        (property (unwrap! (get-property-details property-id) ERR-PROPERTY-NOT-FOUND))
    )
        (asserts! (is-contract-enabled) ERR-DISABLED)
        (asserts! (is-eq tx-sender (get owner property)) ERR-NOT-AUTHORIZED)
        
        ;; Update property status to active
        (map-set properties 
            { property-id: property-id }
            (merge property { active: true })
        )
        
        (ok true)
    )
)