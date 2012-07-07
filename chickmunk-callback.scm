
(declare (hide *callback-proc*
               *exception*))

(define *callback-proc* #f)
(define *exception* #f)


;; we cannot pass the callback proc in the user-data field because
;; its unmanaged pointer would become invalid in the event of a GC.
(define-syntax (start-safe-callbacks x r t)
  (let ([callback-name (cadr x)]
        [foreign-lambda-call (caddr x)])
    `(begin
      (if *callback-proc* (error "chickmunk: nested callbacks not supported"))
      (set! *callback-proc* ,callback-name)
      (set! *exception* #f)
      ,foreign-lambda-call
      (set! *callback-proc* #f)
      (if *exception* (abort *exception*)))))

;; generate safe wrapper around callbacks
;; params:
;;   foreign-each: string-value of function name to invoke (eg
;;   cpSpaceEachBody)
;;
;;   foreign-callback: string-name of foreign function to invoke as
;;   each callback (can be define-external)
;; 
;; needs to call safe-lambda because callback may be external (back to scheme)
(define-syntax (make-safe-callbacks-space x r t)
  (let ([foreign-each (cadr x)]
        [foreign-callback (caddr x)])
    `(lambda (space callback)
       (start-safe-callbacks callback
        ((foreign-safe-lambda* void (((c-pointer void) subject) ; space / body
                                     ((c-pointer void) foreign_callback))
                               ,(conc foreign-each "(subject, foreign_callback, (void*)0);"))
         space (foreign-value ,foreign-callback c-pointer))))
    ))

;; Call *callback-proc*, but handle any exceptions by storing them for
;; later. we want to finish all for-each callbacks so that chipmunk
;; can return and cleanup (unlock space etc). if an error has occured,
;; do nothing on subsequent callbacks
(define (call-and-catch . args)
  (if (not *exception*)
      (handle-exceptions exn
        (begin (set! *exception* exn))
        (apply *callback-proc* args))))


;; ********************
;; for-each callbacks for space (global bodies, shapes & constrains)
(define-external (cb_space_each
                  ((c-pointer void) object) ; from callback: body/shape/constraint
                  ((c-pointer void) data) ; ignored
                  )
  void
  (call-and-catch object))



(define for-each-body (make-safe-callbacks-space "cpSpaceEachBody" "cb_space_each"))
(define for-each-shape (make-safe-callbacks-space "cpSpaceEachShape" "cb_space_each"))
(define for-each-constraint (make-safe-callbacks-space "cpSpaceEachConstraint" "cb_space_each"))

;; *********
;; for-each callbacks on body (shapes, constraints etc belonging to a body)
(define-external (cb_body_each ((c-pointer void) body) ; owner
                               ((c-pointer void) object) ; shape/constraint/arbiter
                               ((c-pointer void) data)) ; ignored
  void
  (call-and-catch body object))

;; using same
(define body-for-each-shape (make-safe-callbacks-space "cpBodyEachShape" "cb_body_each"))
(define body-for-each-constraint (make-safe-callbacks-space "cpBodyEachConstraint" "cb_body_each"))
(define body-for-each-arbiter (make-safe-callbacks-space "cpBodyEachArbiter" "cb_body_each"))


;; **********************
;; space body, shape and constrains lists
;; define convenience functions to get lists of global objects
(define (make-callback->list-proc for-each-proc #!optional (conv-proc (lambda (obj) obj)))
  (lambda args
     (let ([tmp-list '()])
       (apply for-each-proc (append args
                             (list (lambda args
                                (set! tmp-list (cons (apply conv-proc args) tmp-list))))))
       tmp-list)))

(define space-bodies      (make-callback->list-proc for-each-body))
(define space-shapes      (make-callback->list-proc for-each-shape))
(define space-constraints (make-callback->list-proc for-each-constraint))

(declare (hide get-body-subject-callback))
(define (get-body-subject-callback body subject)
  subject)

(define body-shapes      (make-callback->list-proc body-for-each-shape      get-body-subject-callback))
(define body-constraints (make-callback->list-proc body-for-each-constraint get-body-subject-callback))
(define body-arbiters    (make-callback->list-proc body-for-each-arbiter    get-body-subject-callback))

(define-external (cb_space_point_query ((c-pointer "cpShape") shape)
                                       ((c-pointer void) data))
  void
  (call-and-catch shape))

(define for-each-point-query
  (lambda (space point layers group callback)
    (start-safe-callbacks callback
                          ((foreign-safe-lambda* void (((c-pointer void) subject) ; space / body
                                                       ((c-pointer "cpVect") point)
                                                       (unsigned-int layers)
                                                       (unsigned-int group)
                                                       ((c-pointer void) foreign_callback))
                                                 "cpSpacePointQuery"
                                                 "(subject, *point, layers, group"
                                                 "   ,foreign_callback, (void*)0);")
                           space point layers group (foreign-value "cb_space_point_query" c-pointer)))
    ))

;; let's keep argument names for user convenience
(define (point-query space point layers group)
  ((make-callback->list-proc for-each-point-query) space point layers group))
