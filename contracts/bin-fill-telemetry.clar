;; title: bin-fill-telemetry
;; version: 1.0.0
;; summary: Ultrasonic fill-level and contamination sensing for smart waste bins
;; description: Smart contract for monitoring waste bin fill levels, contamination detection,
;;              and automated collection scheduling using ultrasonic sensors and IoT devices

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-BIN-NOT-FOUND (err u101))
(define-constant ERR-INVALID-FILL-LEVEL (err u102))
(define-constant ERR-ALREADY-REGISTERED (err u104))
(define-constant ERR-INVALID-LOCATION (err u105))

;; Fill level thresholds (percentages)
(define-constant FILL-THRESHOLD-LOW u25)
(define-constant FILL-THRESHOLD-MEDIUM u50)
(define-constant FILL-THRESHOLD-HIGH u75)
(define-constant FILL-THRESHOLD-CRITICAL u90)

;; Contamination severity levels
(define-constant CONTAMINATION-NONE u0)
(define-constant CONTAMINATION-LOW u1)
(define-constant CONTAMINATION-MEDIUM u2)
(define-constant CONTAMINATION-HIGH u3)
(define-constant CONTAMINATION-CRITICAL u4)

;; data vars
(define-data-var total-bins uint u0)
(define-data-var maintenance-mode bool false)
(define-data-var sensor-calibration-interval uint u86400)

;; data maps
(define-map bin-registry
  { bin-id: uint }
  {
    location-lat: int,
    location-lng: int,
    bin-type: (string-ascii 20),
    capacity-liters: uint,
    installation-date: uint,
    owner: principal,
    active: bool
  }
)

(define-map bin-telemetry
  { bin-id: uint }
  {
    current-fill-level: uint,
    last-updated: uint,
    sensor-battery: uint,
    temperature: int,
    contamination-level: uint,
    collection-due: bool,
    maintenance-required: bool
  }
)

(define-map sensor-history
  { bin-id: uint, timestamp: uint }
  {
    fill-level: uint,
    contamination-detected: bool,
    sensor-status: (string-ascii 10)
  }
)

(define-map authorized-sensors
  { sensor-id: (string-ascii 32) }
  {
    bin-id: uint,
    last-calibration: uint,
    status: (string-ascii 10),
    authorized-by: principal
  }
)

(define-map collection-requests
  { bin-id: uint }
  {
    requested-at: uint,
    priority: uint,
    estimated-volume: uint,
    status: (string-ascii 15)
  }
)

;; public functions

;; Register a new smart bin in the system
(define-public (register-bin (bin-id uint) (lat int) (lng int) (bin-type (string-ascii 20)) (capacity uint))
  (let (
    (current-total (var-get total-bins))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-none (map-get? bin-registry { bin-id: bin-id })) ERR-ALREADY-REGISTERED)
    (asserts! (and (>= lat -90000000) (<= lat 90000000)) ERR-INVALID-LOCATION)
    (asserts! (and (>= lng -180000000) (<= lng 180000000)) ERR-INVALID-LOCATION)
    
    (map-set bin-registry
      { bin-id: bin-id }
      {
        location-lat: lat,
        location-lng: lng,
        bin-type: bin-type,
        capacity-liters: capacity,
        installation-date: burn-block-height,
        owner: tx-sender,
        active: true
      }
    )
    
    (map-set bin-telemetry
      { bin-id: bin-id }
      {
        current-fill-level: u0,
        last-updated: burn-block-height,
        sensor-battery: u100,
        temperature: 20,
        contamination-level: CONTAMINATION-NONE,
        collection-due: false,
        maintenance-required: false
      }
    )
    
    (var-set total-bins (+ current-total u1))
    (ok bin-id)
  )
)

;; Update fill level from sensor data
(define-public (update-fill-level (bin-id uint) (fill-level uint) (sensor-id (string-ascii 32)))
  (let (
    (bin-data (unwrap! (map-get? bin-registry { bin-id: bin-id }) ERR-BIN-NOT-FOUND))
    (current-telemetry (unwrap! (map-get? bin-telemetry { bin-id: bin-id }) ERR-BIN-NOT-FOUND))
    (sensor-auth (unwrap! (map-get? authorized-sensors { sensor-id: sensor-id }) ERR-UNAUTHORIZED))
  )
    (asserts! (is-eq (get bin-id sensor-auth) bin-id) ERR-UNAUTHORIZED)
    (asserts! (<= fill-level u100) ERR-INVALID-FILL-LEVEL)
    (asserts! (get active bin-data) ERR-BIN-NOT-FOUND)
    
    (map-set bin-telemetry
      { bin-id: bin-id }
      (merge current-telemetry {
        current-fill-level: fill-level,
        last-updated: burn-block-height,
        collection-due: (>= fill-level FILL-THRESHOLD-HIGH)
      })
    )
    
    (map-set sensor-history
      { bin-id: bin-id, timestamp: burn-block-height }
      {
        fill-level: fill-level,
        contamination-detected: false,
        sensor-status: "active"
      }
    )
    
    (if (>= fill-level FILL-THRESHOLD-CRITICAL)
      (try! (schedule-collection bin-id u3))
      (ok true)
    )
    
    (ok fill-level)
  )
)

;; Schedule collection for a bin
(define-public (schedule-collection (bin-id uint) (priority uint))
  (let (
    (bin-data (unwrap! (map-get? bin-registry { bin-id: bin-id }) ERR-BIN-NOT-FOUND))
    (telemetry (unwrap! (map-get? bin-telemetry { bin-id: bin-id }) ERR-BIN-NOT-FOUND))
  )
    (asserts! (get active bin-data) ERR-BIN-NOT-FOUND)
    
    (map-set collection-requests
      { bin-id: bin-id }
      {
        requested-at: burn-block-height,
        priority: priority,
        estimated-volume: (/ (* (get capacity-liters bin-data) (get current-fill-level telemetry)) u100),
        status: "pending"
      }
    )
    
    (ok bin-id)
  )
)

;; Authorize a sensor for a specific bin
(define-public (authorize-sensor (sensor-id (string-ascii 32)) (bin-id uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? bin-registry { bin-id: bin-id })) ERR-BIN-NOT-FOUND)
    
    (map-set authorized-sensors
      { sensor-id: sensor-id }
      {
        bin-id: bin-id,
        last-calibration: burn-block-height,
        status: "active",
        authorized-by: tx-sender
      }
    )
    
    (ok sensor-id)
  )
)

;; read only functions

;; Get bin information
(define-read-only (get-bin-info (bin-id uint))
  (map-get? bin-registry { bin-id: bin-id })
)

;; Get current bin telemetry
(define-read-only (get-bin-telemetry (bin-id uint))
  (map-get? bin-telemetry { bin-id: bin-id })
)

;; Get sensor authorization status
(define-read-only (is-sensor-authorized (sensor-id (string-ascii 32)))
  (map-get? authorized-sensors { sensor-id: sensor-id })
)

;; Get collection request status
(define-read-only (get-collection-request (bin-id uint))
  (map-get? collection-requests { bin-id: bin-id })
)

;; Check if bin needs collection
(define-read-only (needs-collection (bin-id uint))
  (match (map-get? bin-telemetry { bin-id: bin-id })
    telemetry (>= (get current-fill-level telemetry) FILL-THRESHOLD-HIGH)
    false
  )
)

;; Get total number of bins
(define-read-only (get-total-bins)
  (var-get total-bins)
)

;; private functions

;; Validate sensor battery level
(define-private (is-battery-ok (battery-level uint))
  (>= battery-level u20)
)

;; Calculate collection priority based on fill level
(define-private (calculate-priority (fill-level uint) (contamination uint))
  (+
    (if (>= fill-level FILL-THRESHOLD-CRITICAL) u3 u0)
    (if (>= fill-level FILL-THRESHOLD-HIGH) u2 u0)
    (if (>= contamination CONTAMINATION-HIGH) u2 u0)
    u1
  )
)

