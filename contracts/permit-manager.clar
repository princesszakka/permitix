;; Permitix - Transparent Building Permit Management System
;; Main contract handling permit lifecycle from application to expiry

;; ================================
;; CONSTANTS & ERROR CODES
;; ================================

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-status (err u103))
(define-constant err-already-exists (err u104))
(define-constant err-insufficient-fee (err u105))
(define-constant err-expired (err u106))
(define-constant err-invalid-input (err u107))
(define-constant err-not-expired (err u108))
(define-constant err-appeal-window-closed (err u109))

;; Permit statuses
(define-constant status-pending u1)
(define-constant status-under-review u2)
(define-constant status-approved u3)
(define-constant status-rejected u4)
(define-constant status-expired u5)
(define-constant status-appealed u6)

;; Authority roles
(define-constant role-admin u1)
(define-constant role-reviewer u2)
(define-constant role-inspector u3)

;; Fee constants (in microSTX)
(define-constant base-permit-fee u1000000) ;; 1 STX
(define-constant appeal-fee u500000)       ;; 0.5 STX
(define-constant renewal-fee u750000)      ;; 0.75 STX

;; Time constants (in blocks)
(define-constant permit-validity-period u52560)  ;; ~365 days
(define-constant appeal-window u1440)            ;; ~10 days
(define-constant review-timeout u2160)           ;; ~15 days

;; ================================
;; DATA STRUCTURES
;; ================================

;; Authority information
(define-map authorities
  principal
  {
    role: uint,
    name: (string-ascii 100),
    department: (string-ascii 50),
    active: bool,
    permits-reviewed: uint,
    approval-rate: uint
  }
)

;; Applicant information
(define-map applicants
  principal
  {
    name: (string-ascii 100),
    contact: (string-ascii 100),
    verified: bool,
    applications-count: uint,
    approval-rate: uint
  }
)

;; Permit applications
(define-map applications
  uint
  {
    applicant: principal,
    project-title: (string-ascii 200),
    location: (string-ascii 200),
    description: (string-ascii 500),
    estimated-cost: uint,
    permit-type: (string-ascii 50),
    status: uint,
    submitted-at: uint,
    reviewed-at: (optional uint),
    reviewer: (optional principal),
    decision-reason: (optional (string-ascii 300)),
    fee-paid: uint,
    documents-hash: (string-ascii 64)
  }
)

;; Issued permits
(define-map permits
  uint
  {
    application-id: uint,
    permit-number: (string-ascii 50),
    issued-at: uint,
    expires-at: uint,
    holder: principal,
    permit-type: (string-ascii 50),
    status: uint
  }
)

;; Appeal records
(define-map appeals
  uint
  {
    application-id: uint,
    appellant: principal,
    reason: (string-ascii 500),
    submitted-at: uint,
    resolved-at: (optional uint),
    resolution: (optional (string-ascii 300)),
    outcome: (optional bool)
  }
)

;; System statistics
(define-map system-stats
  (string-ascii 20)
  uint
)

;; ================================
;; DATA VARIABLES
;; ================================

(define-data-var next-application-id uint u1)
(define-data-var next-permit-id uint u1)
(define-data-var next-appeal-id uint u1)
(define-data-var system-paused bool false)
(define-data-var total-fees-collected uint u0)

;; ================================
;; PRIVATE FUNCTIONS
;; ================================

;; Calculate permit fee based on estimated cost and permit type
(define-private (calculate-permit-fee (estimated-cost uint) (permit-type (string-ascii 50)))
  (let ((base-fee base-permit-fee))
    (if (> estimated-cost u10000000) ;; Projects over 10 STX
      (+ base-fee (* estimated-cost u50) u1000000) ;; 0.005% of cost + 1 STX extra
      base-fee
    )
  )
)

;; Generate unique permit number
(define-private (generate-permit-number (permit-id uint))
  (concat "PX" (int-to-ascii permit-id))
)

;; Check if caller is authorized authority
(define-private (is-authority (caller principal))
  (is-some (map-get? authorities caller))
)

;; Check if caller has specific role
(define-private (has-role (caller principal) (required-role uint))
  (match (map-get? authorities caller)
    authority-data (>= (get role authority-data) required-role)
    false
  )
)

;; Update system statistics
(define-private (increment-stat (stat-name (string-ascii 20)))
  (let ((current-value (default-to u0 (map-get? system-stats stat-name))))
    (map-set system-stats stat-name (+ current-value u1))
  )
)

;; Validate application input
(define-private (validate-application-input (title (string-ascii 200)) (location (string-ascii 200)) (cost uint))
  (and
    (> (len title) u0)
    (> (len location) u0)
    (> cost u0)
  )
)

;; ================================
;; ADMIN FUNCTIONS
;; ================================

;; Register new authority
(define-public (register-authority (authority principal) (role uint) (name (string-ascii 100)) (department (string-ascii 50)))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-none (map-get? authorities authority)) err-already-exists)
    (asserts! (and (>= role role-inspector) (<= role role-admin)) err-invalid-input)
    (asserts! (> (len name) u0) err-invalid-input)
    (map-set authorities authority {
      role: role,
      name: name,
      department: department,
      active: true,
      permits-reviewed: u0,
      approval-rate: u0
    })
    (increment-stat "authorities-reg")
    (ok true)
  )
)

;; Update authority status
(define-public (update-authority-status (authority principal) (active bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-some (map-get? authorities authority)) err-not-found)
    (map-set authorities authority 
      (merge (unwrap! (map-get? authorities authority) err-not-found)
        {active: active}
      )
    )
    (ok true)
  )
)

;; Emergency pause system
(define-public (pause-system (pause bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set system-paused pause)
    (ok true)
  )
)

;; ================================
;; APPLICANT FUNCTIONS
;; ================================

;; Register new applicant
(define-public (register-applicant (name (string-ascii 100)) (contact (string-ascii 100)))
  (begin
    (asserts! (not (var-get system-paused)) err-unauthorized)
    (asserts! (is-none (map-get? applicants tx-sender)) err-already-exists)
    (asserts! (> (len name) u0) err-invalid-input)
    (map-set applicants tx-sender {
      name: name,
      contact: contact,
      verified: false,
      applications-count: u0,
      approval-rate: u0
    })
    (increment-stat "applicants-reg")
    (ok true)
  )
)

;; Submit permit application
(define-public (submit-application 
  (project-title (string-ascii 200))
  (location (string-ascii 200))
  (description (string-ascii 500))
  (estimated-cost uint)
  (permit-type (string-ascii 50))
  (documents-hash (string-ascii 64))
  (fee-payment uint)
)
  (let (
    (app-id (var-get next-application-id))
    (required-fee (calculate-permit-fee estimated-cost permit-type))
  )
    (asserts! (not (var-get system-paused)) err-unauthorized)
    (asserts! (is-some (map-get? applicants tx-sender)) err-unauthorized)
    (asserts! (validate-application-input project-title location estimated-cost) err-invalid-input)
    (asserts! (>= fee-payment required-fee) err-insufficient-fee)
    
    ;; Create application record
    (map-set applications app-id {
      applicant: tx-sender,
      project-title: project-title,
      location: location,
      description: description,
      estimated-cost: estimated-cost,
      permit-type: permit-type,
      status: status-pending,
      submitted-at: stacks-block-height,
      reviewed-at: none,
      reviewer: none,
      decision-reason: none,
      fee-paid: fee-payment,
      documents-hash: documents-hash
    })
    
    ;; Update applicant stats
    (map-set applicants tx-sender
      (merge (unwrap! (map-get? applicants tx-sender) err-not-found)
        {applications-count: (+ (get applications-count (unwrap! (map-get? applicants tx-sender) err-not-found)) u1)}
      )
    )
    
    ;; Update system stats and fees
    (var-set next-application-id (+ app-id u1))
    (var-set total-fees-collected (+ (var-get total-fees-collected) fee-payment))
    (increment-stat "apps-submitted")
    
    (ok app-id)
  )
)

;; ================================
;; AUTHORITY FUNCTIONS
;; ================================

;; Review permit application
(define-public (review-application (app-id uint) (decision uint) (reason (string-ascii 300)))
  (let (
    (application (unwrap! (map-get? applications app-id) err-not-found))
    (authority-info (unwrap! (map-get? authorities tx-sender) err-unauthorized))
  )
    (asserts! (not (var-get system-paused)) err-unauthorized)
    (asserts! (get active authority-info) err-unauthorized)
    (asserts! (has-role tx-sender role-reviewer) err-unauthorized)
    (asserts! (is-eq (get status application) status-pending) err-invalid-status)
    (asserts! (or (is-eq decision status-approved) (is-eq decision status-rejected)) err-invalid-input)
    
    ;; Update application with decision
    (map-set applications app-id
      (merge application {
        status: decision,
        reviewed-at: (some stacks-block-height),
        reviewer: (some tx-sender),
        decision-reason: (some reason)
      })
    )
    
    ;; Update authority stats
    (map-set authorities tx-sender
      (merge authority-info
        {permits-reviewed: (+ (get permits-reviewed authority-info) u1)}
      )
    )
    
    ;; If approved, issue permit
    (if (is-eq decision status-approved)
      (begin
        (try! (issue-permit app-id))
        (increment-stat "apps-approved")
      )
      (increment-stat "apps-rejected")
    )
    
    (ok true)
  )
)

;; Issue permit for approved application
(define-private (issue-permit (app-id uint))
  (let (
    (application (unwrap! (map-get? applications app-id) err-not-found))
    (permit-id (var-get next-permit-id))
    (permit-number (generate-permit-number permit-id))
  )
    (map-set permits permit-id {
      application-id: app-id,
      permit-number: permit-number,
      issued-at: stacks-block-height,
      expires-at: (+ stacks-block-height permit-validity-period),
      holder: (get applicant application),
      permit-type: (get permit-type application),
      status: status-approved
    })
    
    (var-set next-permit-id (+ permit-id u1))
    (increment-stat "permits-issued")
    (ok permit-id)
  )
)

;; ================================
;; APPEAL FUNCTIONS
;; ================================

;; Submit appeal for rejected application
(define-public (submit-appeal (app-id uint) (reason (string-ascii 500)))
  (let (
    (application (unwrap! (map-get? applications app-id) err-not-found))
    (appeal-id (var-get next-appeal-id))
  )
    (asserts! (not (var-get system-paused)) err-unauthorized)
    (asserts! (is-eq (get applicant application) tx-sender) err-unauthorized)
    (asserts! (is-eq (get status application) status-rejected) err-invalid-status)
    (asserts! (< (- stacks-block-height (unwrap! (get reviewed-at application) err-invalid-status)) appeal-window) err-appeal-window-closed)
    
    ;; Record appeal
    (map-set appeals appeal-id {
      application-id: app-id,
      appellant: tx-sender,
      reason: reason,
      submitted-at: stacks-block-height,
      resolved-at: none,
      resolution: none,
      outcome: none
    })
    
    ;; Update application status
    (map-set applications app-id
      (merge application {status: status-appealed})
    )
    
    (var-set next-appeal-id (+ appeal-id u1))
    (increment-stat "appeals-submitted")
    (ok appeal-id)
  )
)

;; ================================
;; PUBLIC READ-ONLY FUNCTIONS
;; ================================

;; Get application details
(define-read-only (get-application (app-id uint))
  (map-get? applications app-id)
)

;; Get permit details
(define-read-only (get-permit (permit-id uint))
  (map-get? permits permit-id)
)

;; Get authority information
(define-read-only (get-authority (authority principal))
  (map-get? authorities authority)
)

;; Get applicant information
(define-read-only (get-applicant (applicant principal))
  (map-get? applicants applicant)
)

;; Get appeal details
(define-read-only (get-appeal (appeal-id uint))
  (map-get? appeals appeal-id)
)

;; Get system statistics
(define-read-only (get-system-stat (stat-name (string-ascii 20)))
  (map-get? system-stats stat-name)
)

;; Check if permit is valid and not expired
(define-read-only (is-permit-valid (permit-id uint))
  (match (map-get? permits permit-id)
    permit-data 
      (and 
        (is-eq (get status permit-data) status-approved)
        (< stacks-block-height (get expires-at permit-data))
      )
    false
  )
)

;; Get current fees
(define-read-only (get-permit-fee (estimated-cost uint) (permit-type (string-ascii 50)))
  (calculate-permit-fee estimated-cost permit-type)
)

;; Get total fees collected
(define-read-only (get-total-fees-collected)
  (var-get total-fees-collected)
)

;; Get system status
(define-read-only (get-system-status)
  {
    paused: (var-get system-paused),
    total-applications: (- (var-get next-application-id) u1),
    total-permits: (- (var-get next-permit-id) u1),
    total-appeals: (- (var-get next-appeal-id) u1),
    fees-collected: (var-get total-fees-collected)
  }
)
