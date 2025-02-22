(defpackage #:ultralisp/models/dist
  (:use #:cl)
  (:import-from #:ultralisp/models/versioned
                #:versioned
                #:object-version)
  (:import-from #:ultralisp/models/source)
  (:import-from #:alexandria
                #:make-keyword)
  (:import-from #:ultralisp/db
                #:with-transaction)
  (:import-from #:mito
                #:object-id)
  (:import-from #:ultralisp/protocols/enabled
                #:enabled-p)
  (:import-from #:ultralisp/utils/db
                #:deflate-keyword
                #:inflate-keyword)
  (:export
   #:dist
   #:dist-name
   #:find-dist
   #:dist-state
   #:common-dist
   #:bound-dist
   #:disable-reason
   #:ensure-dist
   #:get-or-create-pending-version
   #:dist-equal
   #:get-pending-dists
   #:dist-built-at
   #:get-prepared-dists
   #:latest-dists
   #:dist-quicklisp-version
   #:find-dist-version
   #:lisp-implementation
   #:public-dists))
(in-package #:ultralisp/models/dist)


(defclass dist (versioned)
  ((name :col-type (:text)
         :initarg :name
         :reader dist-name)
   (quicklisp-version :col-type (:text)
                      :initform ""
                      :documentation "This field is updated by :function:`ultralisp/builder::build-pending-dist`.
                                      It contains a datetime of the moment when the distribution was built."
                      :accessor dist-quicklisp-version)
   (built-at :col-type (or :timestamptz
                           :null)
             :initform nil
             :accessor dist-built-at)
   (state :col-type (:text)
          :initarg :state
          :initform :pending
          :type (member
                 ;; Initial state, in this state new versions of
                 ;; project sources can be associated with a dist:
                 :pending
                 ;; In this state no new sources can be attached
                 ;; to the dist and it's quicklisp-version
                 ;; is already generated. Now it just waits for
                 ;; metadata generation:
                 :prepared
                 ;; Metadata was generated and uploaded to the storage,
                 ;; at the moment when state becomes :ready, built-at
                 ;; slot gets filled: 
                 :ready)
          :accessor dist-state
          :inflate #'inflate-keyword
          :deflate #'deflate-keyword)
   (lisp-implementation :col-type (:text)
                        :initarg :lisp-implementation
                        :initform :sbcl
                        :accessor lisp-implementation
                        :inflate #'inflate-keyword
                        :deflate #'deflate-keyword
                        :documentation "A keyword like :SBCL or :LISPWORKS, denoting the lisp implementation
                                        under which this sources include into this dist should be checked."))
  (:unique-keys name)
  ;; It is important to use symbols from versioned package
  ;; because otherwise mito is not able to find slots in the object
  ;; when doing update-dao
  (:primary-key ultralisp/models/versioned::id
                ultralisp/models/versioned::version)
  (:metaclass mito:dao-table-class))


(defmethod print-object ((obj dist) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream
            "~A (v~A)"
            (dist-name obj)
            (object-version obj))))


(defun find-dist (name &key (raise-error t)
                            (quicklisp-version nil quicklisp-version-p))
  (let ((result (apply #'mito.dao:find-dao
                       'dist
                       :name name
                       (append
                        (unless quicklisp-version-p
                          (list :latest "true"))
                        (when quicklisp-version-p
                          (list :quicklisp-version quicklisp-version))))))
    (when (and (null result)
               raise-error)
      (error "Unable to find dist with name \"~A\"" name))
    result))


(defun common-dist ()
  (find-dist "ultralisp"))


(defun public-dists ()
  (remove-if #'null
             (list (common-dist)
                   (find-dist "lispworks" :raise-error nil))))


(defclass bound-dist ()
  ((dist :initarg :dist
         :reader dist)
   (enabled :initarg :enabled
            :reader enabled-p)
   (disable-reason :initarg :disable-reason
                   :reader disable-reason)
   (include-reason :initarg :include-reason
                   :reader include-reason)))


;; We'll define a few readers to make bound-dist work the same like usual dist does:
(defmethod dist-name ((obj bound-dist))
  (dist-name (dist obj)))

(defmethod dist-state ((obj bound-dist))
  (dist-state (dist obj)))

(defmethod dist-quicklisp-version ((obj bound-dist))
  (dist-quicklisp-version (dist obj)))

(defmethod object-id ((obj bound-dist))
  (object-id (dist obj)))

(defmethod object-version ((obj bound-dist))
  (object-version (dist obj)))

(defmethod lisp-implementation ((obj bound-dist))
  (lisp-implementation (dist obj)))


(defmethod print-object ((obj bound-dist) stream)
  (let ((dist (dist obj)))
    (print-unreadable-object (obj stream :type t)
      (format stream
              "~A (v~A)"
              (dist-name dist)
              (object-version dist))
      (unless (enabled-p obj)
        (format stream " disabled")))))


(defgeneric ensure-dist (value)
  (:method ((dist dist))
    dist)
  (:method ((bound bound-dist))
    (dist bound))
  (:method ((name string))
    (find-dist name)))


(defun get-next-dist-version (dist)
  "Returns a number to be the next version for the dist."
  (getf (first
         (mito:retrieve-by-sql "
     SELECT COALESCE(MAX(version) + 1, 0) as version
       FROM dist
      WHERE id = ?" :binds (list (object-id dist))))
        :version))


(defun get-or-create-pending-version (dist)
  (with-transaction
    (let* ((id
             (object-id dist))
           (existing (mito.dao:find-dao 'dist
                                        :id id
                                        :state :pending)))
      (or existing
          (mito:create-dao 'dist
                           :id id
                           :version (get-next-dist-version dist)
                           :name (dist-name dist)
                           :state :pending
                           :lisp-implementation (lisp-implementation dist))))))


(defun get-pending-dists ()
  (mito.dao:retrieve-dao 'dist
                         :state :pending))

(defun get-prepared-dists ()
  (mito.dao:retrieve-dao 'dist
                         :state :prepared))


(defun dist-equal (left-dist right-dist)
  (and (equal (object-id left-dist)
              (object-id right-dist))
       (equal (object-version left-dist)
              (object-version right-dist))))


(defun latest-dists (&key (limit 10))
  (mito:select-dao 'dist
    (sxql:order-by (:desc :created-at))
    (sxql:limit limit)))


(defun find-dist-version (id version)
  (mito:find-dao 'dist
                 :id id
                 :version version))


(defun change-implementation (dist-name new-implementation)
  (check-type dist-name string)
  (check-type new-implementation (member :sbcl :lispworks))
  (let ((dist (find-dist dist-name)))
    (setf (lisp-implementation dist)
          new-implementation)
    (mito:save-dao dist)))
