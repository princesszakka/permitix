;; Permitix Validator - Document Validation & Compliance Verification
;; Advanced validation system for building permits and documentation

;; ================================
;; CONSTANTS & ERROR CODES
;; ================================

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-found (err u201))
(define-constant err-unauthorized (err u202))
(define-constant err-invalid-status (err u203))
(define-constant err-already-exists (err u204))
(define-constant err-invalid-input (err u205))
(define-constant err-expired-document (err u206))
(define-constant err-insufficient-score (err u207))
(define-constant err-duplicate-report (err u208))
(define-constant err-invalid-hash (err u209))

;; Document types
(define-constant doc-type-license u1)
(define-constant doc-type-insurance u2)
(define-constant doc-type-financial u3)
(define-constant doc-type-technical u4)
(define-constant doc-type-environmental u5)
(define-constant doc-type-zoning u6)

;; Validation statuses
(define-constant validation-pending u1)
(define-constant validation-approved u2)
(define-constant validation-rejected u3)
(define-constant validation-expired u4)

;; Compliance levels
(define-constant compliance-full u1)
(define-constant compliance-partial u2)
(define-constant compliance-non-compliant u3)

;; Report statuses
(define-constant report-open u1)
(define-constant report-investigating u2)
(define-constant report-resolved u3)
(define-constant report-dismissed u4)

;; Minimum scores for qualification
(define-constant min-qualification-score u700) ;; Out of 1000
(define-constant min-financial-score u600)
(define-constant min-technical-score u750)

;; Time constants (in blocks)
(define-constant document-validity-period u26280) ;; ~182 days
(define-constant validation-timeout u720)         ;; ~5 days
(define-constant investigation-period u2160)      ;; ~15 days

;; ================================
;; DATA STRUCTURES
;; ================================

;; Document validators (authorized personnel)
(define-map validators
  principal
  {
    name: (string-ascii 100),
    specialization: (string-ascii 50),
    active: bool,
    documents-validated: uint,
    accuracy-rating: uint,
    authorized-types: (list 10 uint)
  }
)

;; Document submissions
(define-map documents
  uint
  {
    submitter: principal,
    document-type: uint,
    document-hash: (string-ascii 64),
    submitted-at: uint,
    expires-at: uint,
    validation-status: uint,
    validator: (optional principal),
    validated-at: (optional uint),
    validation-notes: (optional (string-ascii 300)),
    compliance-score: uint
  }
)

;; Compliance checks
(define-map compliance-checks
  uint
  {
    application-id: uint,
    checked-at: uint,
    checker: principal,
    zoning-compliance: uint,
    building-code-compliance: uint,
    environmental-compliance: uint,
    safety-compliance: uint,
    overall-score: uint,
    notes: (string-ascii 500)
  }
)

;; Inspector assignments
(define-map inspections
  uint
  {
    application-id: uint,
    inspector: principal,
    inspection-type: (string-ascii 50),
    scheduled-at: uint,
    completed-at: (optional uint),
    status: uint,
    findings: (optional (string-ascii 500)),
    compliance-rating: uint
  }
)

;; Violation reports
(define-map violation-reports
  uint
  {
    reporter: principal,
    permit-id: uint,
    violation-type: (string-ascii 100),
    description: (string-ascii 500),
    evidence-hash: (string-ascii 64),
    reported-at: uint,
    status: uint,
    investigator: (optional principal),
    investigation-started: (optional uint),
    resolution: (optional (string-ascii 300)),
    resolved-at: (optional uint)
  }
)

;; Performance tracking
(define-map performance-records
  principal
  {
    total-validations: uint,
    accuracy-score: uint,
    response-time-avg: uint,
    specialization-scores: (list 6 uint),
    last-updated: uint
  }
)

;; Contractor qualifications
(define-map contractor-qualifications
  principal
  {
    license-score: uint,
    financial-score: uint,
    technical-score: uint,
    experience-score: uint,
    safety-score: uint,
    overall-qualification: uint,
    last-assessment: uint,
    qualification-expires: uint
  }
)

;; ================================
;; DATA VARIABLES
;; ================================

(define-data-var next-document-id uint u1)
(define-data-var next-compliance-id uint u1)
(define-data-var next-inspection-id uint u1)
(define-data-var next-report-id uint u1)
(define-data-var validator-count uint u0)
(define-data-var total-documents-validated uint u0)
(define-data-var system-active bool true)

;; ================================
;; PRIVATE FUNCTIONS
;; ================================

;; Calculate document expiry based on type
(define-private (calculate-document-expiry (doc-type uint))
  (+ stacks-block-height
    (if (or (is-eq doc-type doc-type-license) (is-eq doc-type doc-type-insurance))
      document-validity-period
      (* document-validity-period u2) ;; Financial and technical docs last longer
    )
  )
)

;; Check if validator is authorized for document type
(define-private (is-validator-authorized (validator principal) (doc-type uint))
  (match (map-get? validators validator)
    validator-data (is-some (index-of (get authorized-types validator-data) doc-type))
    false
  )
)

;; Calculate overall qualification score
(define-private (calculate-qualification-score (license uint) (financial uint) (technical uint) (experience uint) (safety uint))
  (/ (+ (* license u25) (* financial u20) (* technical u25) (* experience u15) (* safety u15)) u100)
)

;; Update validator performance
(define-private (update-validator-performance (validator principal))
  (let (
    (current-record (default-to 
      {total-validations: u0, accuracy-score: u800, response-time-avg: u100, specialization-scores: (list u800 u800 u800 u800 u800 u800), last-updated: u0}
      (map-get? performance-records validator)
    ))
  )
    (map-set performance-records validator
      (merge current-record {
        total-validations: (+ (get total-validations current-record) u1),
        last-updated: stacks-block-height
      })
    )
  )
)

;; Validate document hash format
(define-private (is-valid-hash (hash (string-ascii 64)))
  (and (is-eq (len hash) u64) (> (len hash) u0))
)

;; ================================
;; ADMIN FUNCTIONS
;; ================================

;; Add new validator
(define-public (add-validator (validator principal) (name (string-ascii 100)) (specialization (string-ascii 50)) (authorized-types (list 10 uint)))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-none (map-get? validators validator)) err-already-exists)
    (asserts! (> (len name) u0) err-invalid-input)
    (asserts! (> (len authorized-types) u0) err-invalid-input)
    
    (map-set validators validator {
      name: name,
      specialization: specialization,
      active: true,
      documents-validated: u0,
      accuracy-rating: u800, ;; Starting rating
      authorized-types: authorized-types
    })
    
    (var-set validator-count (+ (var-get validator-count) u1))
    (ok true)
  )
)

;; Update validator status
(define-public (update-validator-status (validator principal) (active bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-some (map-get? validators validator)) err-not-found)
    
    (map-set validators validator
      (merge (unwrap! (map-get? validators validator) err-not-found) {active: active})
    )
    (ok true)
  )
)

;; System control
(define-public (set-system-active (active bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set system-active active)
    (ok true)
  )
)

;; ================================
;; DOCUMENT VALIDATION FUNCTIONS
;; ================================

;; Submit document for validation
(define-public (submit-document (doc-type uint) (document-hash (string-ascii 64)))
  (let (
    (doc-id (var-get next-document-id))
    (expires-at (calculate-document-expiry doc-type))
  )
    (asserts! (var-get system-active) err-unauthorized)
    (asserts! (is-valid-hash document-hash) err-invalid-hash)
    (asserts! (and (>= doc-type doc-type-license) (<= doc-type doc-type-zoning)) err-invalid-input)
    
    (map-set documents doc-id {
      submitter: tx-sender,
      document-type: doc-type,
      document-hash: document-hash,
      submitted-at: stacks-block-height,
      expires-at: expires-at,
      validation-status: validation-pending,
      validator: none,
      validated-at: none,
      validation-notes: none,
      compliance-score: u0
    })
    
    (var-set next-document-id (+ doc-id u1))
    (ok doc-id)
  )
)

;; Validate submitted document
(define-public (validate-document (doc-id uint) (approved bool) (compliance-score uint) (notes (string-ascii 300)))
  (let (
    (document (unwrap! (map-get? documents doc-id) err-not-found))
    (validator-info (unwrap! (map-get? validators tx-sender) err-unauthorized))
  )
    (asserts! (var-get system-active) err-unauthorized)
    (asserts! (get active validator-info) err-unauthorized)
    (asserts! (is-validator-authorized tx-sender (get document-type document)) err-unauthorized)
    (asserts! (is-eq (get validation-status document) validation-pending) err-invalid-status)
    (asserts! (<= compliance-score u1000) err-invalid-input)
    
    ;; Update document validation
    (map-set documents doc-id
      (merge document {
        validation-status: (if approved validation-approved validation-rejected),
        validator: (some tx-sender),
        validated-at: (some stacks-block-height),
        validation-notes: (some notes),
        compliance-score: compliance-score
      })
    )
    
    ;; Update validator stats
    (map-set validators tx-sender
      (merge validator-info
        {documents-validated: (+ (get documents-validated validator-info) u1)}
      )
    )
    
    (update-validator-performance tx-sender)
    (var-set total-documents-validated (+ (var-get total-documents-validated) u1))
    (ok true)
  )
)

;; ================================
;; COMPLIANCE CHECKING FUNCTIONS
;; ================================

;; Run comprehensive compliance check
(define-public (check-compliance 
  (application-id uint)
  (zoning-score uint)
  (building-code-score uint)
  (environmental-score uint)
  (safety-score uint)
  (notes (string-ascii 500))
)
  (let (
    (compliance-id (var-get next-compliance-id))
    (overall-score (/ (+ zoning-score building-code-score environmental-score safety-score) u4))
  )
    (asserts! (var-get system-active) err-unauthorized)
    (asserts! (is-some (map-get? validators tx-sender)) err-unauthorized)
    (asserts! (and (<= zoning-score u1000) (<= building-code-score u1000) (<= environmental-score u1000) (<= safety-score u1000)) err-invalid-input)
    
    (map-set compliance-checks compliance-id {
      application-id: application-id,
      checked-at: stacks-block-height,
      checker: tx-sender,
      zoning-compliance: zoning-score,
      building-code-compliance: building-code-score,
      environmental-compliance: environmental-score,
      safety-compliance: safety-score,
      overall-score: overall-score,
      notes: notes
    })
    
    (var-set next-compliance-id (+ compliance-id u1))
    (ok compliance-id)
  )
)

;; Update contractor qualifications
(define-public (update-qualifications (contractor principal) (license uint) (financial uint) (technical uint) (experience uint) (safety uint))
  (let (
    (overall-score (calculate-qualification-score license financial technical experience safety))
  )
    (asserts! (is-some (map-get? validators tx-sender)) err-unauthorized)
    (asserts! (and (<= license u1000) (<= financial u1000) (<= technical u1000) (<= experience u1000) (<= safety u1000)) err-invalid-input)
    
    (map-set contractor-qualifications contractor {
      license-score: license,
      financial-score: financial,
      technical-score: technical,
      experience-score: experience,
      safety-score: safety,
      overall-qualification: overall-score,
      last-assessment: stacks-block-height,
      qualification-expires: (+ stacks-block-height document-validity-period)
    })
    
    (ok overall-score)
  )
)

;; ================================
;; INSPECTION FUNCTIONS
;; ================================

;; Assign inspector for site visit
(define-public (assign-inspector (application-id uint) (inspector principal) (inspection-type (string-ascii 50)) (scheduled-at uint))
  (let (
    (inspection-id (var-get next-inspection-id))
  )
    (asserts! (is-some (map-get? validators tx-sender)) err-unauthorized)
    (asserts! (is-some (map-get? validators inspector)) err-not-found)
    (asserts! (> scheduled-at stacks-block-height) err-invalid-input)
    
    (map-set inspections inspection-id {
      application-id: application-id,
      inspector: inspector,
      inspection-type: inspection-type,
      scheduled-at: scheduled-at,
      completed-at: none,
      status: validation-pending,
      findings: none,
      compliance-rating: u0
    })
    
    (var-set next-inspection-id (+ inspection-id u1))
    (ok inspection-id)
  )
)

;; Complete inspection report
(define-public (complete-inspection (inspection-id uint) (findings (string-ascii 500)) (compliance-rating uint))
  (let (
    (inspection (unwrap! (map-get? inspections inspection-id) err-not-found))
  )
    (asserts! (is-eq tx-sender (get inspector inspection)) err-unauthorized)
    (asserts! (is-eq (get status inspection) validation-pending) err-invalid-status)
    (asserts! (<= compliance-rating u1000) err-invalid-input)
    
    (map-set inspections inspection-id
      (merge inspection {
        completed-at: (some stacks-block-height),
        status: validation-approved,
        findings: (some findings),
        compliance-rating: compliance-rating
      })
    )
    
    (ok true)
  )
)

;; ================================
;; VIOLATION REPORTING FUNCTIONS
;; ================================

;; Report permit violation
(define-public (report-violation (permit-id uint) (violation-type (string-ascii 100)) (description (string-ascii 500)) (evidence-hash (string-ascii 64)))
  (let (
    (report-id (var-get next-report-id))
  )
    (asserts! (var-get system-active) err-unauthorized)
    (asserts! (is-valid-hash evidence-hash) err-invalid-hash)
    (asserts! (> (len violation-type) u0) err-invalid-input)
    
    (map-set violation-reports report-id {
      reporter: tx-sender,
      permit-id: permit-id,
      violation-type: violation-type,
      description: description,
      evidence-hash: evidence-hash,
      reported-at: stacks-block-height,
      status: report-open,
      investigator: none,
      investigation-started: none,
      resolution: none,
      resolved-at: none
    })
    
    (var-set next-report-id (+ report-id u1))
    (ok report-id)
  )
)

;; Start investigation of violation report
(define-public (investigate-report (report-id uint))
  (let (
    (report (unwrap! (map-get? violation-reports report-id) err-not-found))
  )
    (asserts! (is-some (map-get? validators tx-sender)) err-unauthorized)
    (asserts! (is-eq (get status report) report-open) err-invalid-status)
    
    (map-set violation-reports report-id
      (merge report {
        status: report-investigating,
        investigator: (some tx-sender),
        investigation-started: (some stacks-block-height)
      })
    )
    
    (ok true)
  )
)

;; Resolve violation report
(define-public (resolve-report (report-id uint) (resolution (string-ascii 300)) (dismissed bool))
  (let (
    (report (unwrap! (map-get? violation-reports report-id) err-not-found))
  )
    (asserts! (is-eq tx-sender (unwrap! (get investigator report) err-unauthorized)) err-unauthorized)
    (asserts! (is-eq (get status report) report-investigating) err-invalid-status)
    
    (map-set violation-reports report-id
      (merge report {
        status: (if dismissed report-dismissed report-resolved),
        resolution: (some resolution),
        resolved-at: (some stacks-block-height)
      })
    )
    
    (ok true)
  )
)

;; ================================
;; READ-ONLY FUNCTIONS
;; ================================

;; Get document details
(define-read-only (get-document (doc-id uint))
  (map-get? documents doc-id)
)

;; Get validator information
(define-read-only (get-validator (validator principal))
  (map-get? validators validator)
)

;; Get compliance check results
(define-read-only (get-compliance-check (compliance-id uint))
  (map-get? compliance-checks compliance-id)
)

;; Get inspection details
(define-read-only (get-inspection (inspection-id uint))
  (map-get? inspections inspection-id)
)

;; Get violation report
(define-read-only (get-violation-report (report-id uint))
  (map-get? violation-reports report-id)
)

;; Get contractor qualifications
(define-read-only (get-contractor-qualifications (contractor principal))
  (map-get? contractor-qualifications contractor)
)

;; Get validator performance
(define-read-only (get-performance-record (validator principal))
  (map-get? performance-records validator)
)

;; Check if contractor is qualified
(define-read-only (is-contractor-qualified (contractor principal))
  (match (map-get? contractor-qualifications contractor)
    qualifications
      (and
        (>= (get overall-qualification qualifications) min-qualification-score)
        (>= (get financial-score qualifications) min-financial-score)
        (>= (get technical-score qualifications) min-technical-score)
        (> (get qualification-expires qualifications) stacks-block-height)
      )
    false
  )
)

;; Get system statistics
(define-read-only (get-system-statistics)
  {
    total-validators: (var-get validator-count),
    total-documents: (- (var-get next-document-id) u1),
    total-validations: (var-get total-documents-validated),
    total-compliance-checks: (- (var-get next-compliance-id) u1),
    total-inspections: (- (var-get next-inspection-id) u1),
    total-violation-reports: (- (var-get next-report-id) u1),
    system-active: (var-get system-active)
  }
)
