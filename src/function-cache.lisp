(in-package :function-cache)
(cl-interpol:enable-interpol-syntax)

;;;; TODO, ideas: Purger threads, MRU heap cache,
;;;; refreshable caches (need to store actual args as well (instead of just
;;;; cache key), which has storage implications)

(defclass cache-capacity-mixin ()
  ((capacity
    :accessor capacity :initarg :capacity :initform nil
    :documentation "The maximum number of objects cached, when we hit this we
    will reduce the number of cached entries by reduce-by-ratio")
   (reduce-by-ratio
    :accessor reduce-by-ratio :initarg :reduce-by-ratio :initform .2
    :documentation "Remove the oldest reduce-by-ratio entries (eg: .2 or 20%)")))

(defclass function-cache ()
  ((cached-results :accessor cached-results :initform nil :initarg
                   :cached-results)
   (timeout :accessor timeout :initform nil :initarg :timeout)
   (body-fn :accessor body-fn :initform nil :initarg :body-fn)
   (name :accessor name :initform nil :initarg :name)
   (lambda-list :accessor lambda-list :initform nil :initarg :lambda-list)
   (shared-results? :accessor shared-results? :initform nil :initarg
                    :shared-results?)
   )
  (:documentation "an object that contains the cached results of function calls
    the original function to be run, to set cached values
    and other cache configuration parameters.  This class is mostly intended
    to be abstract with hash-table-function-cache, and thunk-cache being the
    current concrete classes"))

(defmethod print-object ((o function-cache) s)
  "Print the auto-print-items for this instance."
  (print-unreadable-object (o s :type t :identity t)
    (ignore-errors
     (iter (for c in '(name))
       (for v = (ignore-errors (funcall c o)))
       (when v (format s "~A:~S " c v))))))

(defmethod cached-results :around ((cache function-cache))
  "Coerce the refernce to the results into something we can use"
  (let ((result (call-next-method)))
    (typecase result
      (null nil)
      (function (funcall result))
      (symbol (cond ((boundp result) (symbol-value result))
                    ((fboundp result) (funcall result))))
      (t result))))

(defclass thunk-cache (function-cache)
  ()
  (:documentation "a cache optimized for functions of no arguments
     (uses a cons for caching)"))

(defclass single-cell-function-cache (function-cache)
  ((test :accessor test :initarg :test :initform #'equal))
  (:documentation "a cache that stores only the most recent result of running
     the body"))

(defvar *default-hash-init-args*
  `(:test equal
    #+sbcl ,@'(:synchronized t)
    ))

(defclass hash-table-function-cache (function-cache)
  ((hash-init-args
    :accessor hash-init-args
    :initform *default-hash-init-args*
    :initarg :hash-init-args))
  (:documentation "a function cache that uses a hash-table to store results"))

(defclass hash-table-function-cache-with-capacity (cache-capacity-mixin hash-table-function-cache)
  ()
  (:documentation "a function cache that uses a hash-table to store results with a max capacity"))

(defmethod initialize-instance :after
    ((cache function-cache) &key &allow-other-keys)
  (ensure-cache-backing cache))

(defgeneric ensure-cache-backing (cache)
  (:documentation "ensures that cached-results has the expected init value")
  (:method ((cache function-cache)) t)
  (:method ((cache single-cell-function-cache))
    (unless (slot-value cache 'cached-results)
      (setf (slot-value cache 'cached-results)
            (cons nil (cons nil nil)))))
  (:method ((cache hash-table-function-cache))
    (unless (slot-value cache 'cached-results)
      (setf (slot-value cache 'cached-results)
            (apply #'make-hash-table (hash-init-args cache))))))

(defgeneric expired? ( cache result-timeout )
  (:documentation "Determines if the cache entry is expired")
  (:method (cache result-timeout)
    (let ((timeout (timeout cache)))
      (cond
        ;; things never expire
        ((null timeout) nil)
        ;; no valid cache entry - must be expiredish
        ((null result-timeout) t)
        ;; we have timeouts and times to compare, are we past expiration
        (t (let ((expires-at (+ timeout result-timeout)))
             (<= expires-at (get-universal-time))))
        ))))

(defgeneric get-cached-value (cache cache-key)
  (:documentation "returns the result-values-list and at what time it was cached")
  (:method ((cache hash-table-function-cache) cache-key)
    ;; if we get no hash when we expect one then it probably means
    ;; that we should just run tthe body (eg: http-context cached results
    ;; a valid http context)
    (let* ((hash (cached-results cache))
           (cons (when hash (gethash cache-key (cached-results cache))))
           (res (car cons))
           (cached-at (cdr cons)))
      (values res cached-at)))
  (:method ((cache thunk-cache) cache-key)
    (declare (ignore cache-key))
    (let* ((res (car (cached-results cache)))
           (cached-at (cdr (cached-results cache))))
      (values res cached-at)))
  (:method ((cache single-cell-function-cache) cache-key)
    (let* ((res (cached-results cache))
           (key (car res))
           (val (cadr res))
           (cached-at (cddr res)))
      (when (funcall (test cache) cache-key key)
        (values val cached-at)))))

(defgeneric at-cache-capacity? (cache)
  (:method (cache) nil)
  (:method ((cache cache-capacity-mixin))
    (and
     (capacity cache)
     (>= (cached-results-count cache)
         (capacity cache)))))

(defgeneric reduce-cached-set (cache)
  (:method ((cache hash-table-function-cache))
    ;; probably not super efficient and therefor probably likely to be a point of slowdown
    ;; in code we are trying to make fast with caching, an LRU/MRU heap would be a better
    ;; data structure for supporting this operation
    (let ((ht (cached-results cache))
          (number-to-remove (ceiling (* (capacity cache) (reduce-by-ratio cache)))))
      (iter
        (for i from 0 to number-to-remove)
        (for (key . val) in
             (sort
              (alexandria:hash-table-alist ht)
              #'<= :key #'cddr))
        (remhash key ht)))))

(defgeneric (setf get-cached-value) (new cache cache-key)
  (:documentation "Set the cached value for the cache key")
  (:method :before (new (cache cache-capacity-mixin) cache-key)
    (when (at-cache-capacity? cache)
      (reduce-cached-set cache)))
  (:method (new (cache single-cell-function-cache) cache-key)
    (setf (cached-results cache)
          (cons cache-key (cons new (get-universal-time)))))
  (:method (new (cache hash-table-function-cache) cache-key)
    ;; without our shared hash, we cannot cache
    (let ((hash (cached-results cache)))
      (when hash
        (setf (gethash cache-key hash)
              (cons new (get-universal-time))))))
  (:method (new (cache thunk-cache) cache-key)
    (declare (ignore cache-key))
    (setf (cached-results cache)
          (cons new (get-universal-time)))))

(defgeneric defcached-hashkey (thing)
  (:documentation "Turns a list of arguments into a valid cache-key
    (usually a tree of primatives)")
  (:method ((thing T))
    (typecase thing
      (null nil)
      (list (iter (for i in thing)
              (collect (defcached-hashkey i))))
      (t thing))))

(defgeneric compute-cache-key (cache thing)
  (:documentation "Used to assemble cache keys for function-cache objects")
  (:method ((cache function-cache) thing)
    (let ((rest (ensure-list (defcached-hashkey thing))))
      (if (shared-results? cache)
          (list* (name cache) rest)
          rest))))

(defun %insert-into-cache (cache args &key (cache-key (compute-cache-key cache args)))
  "Simple helper to run the body, store the results in the cache and then return them"
  (let ((results (multiple-value-list (apply (body-fn cache) args))))
    (setf (get-cached-value cache cache-key) results)
    (apply #'values results)))

(defgeneric cacher (cache args)
  (:documentation "A function that takes a cache object and an arg list
    and either runs the computation and fills the caches or retrieves
    the cached value")
  (:method ((cache function-cache) args
            &aux (cache-key (compute-cache-key cache args)))
    (multiple-value-bind (cached-res cached-at)
        (get-cached-value cache cache-key)
      (if (or (null cached-at) (expired? cache cached-at))
          (%insert-into-cache cache args)
          (apply #'values cached-res)))))

(defvar *cache-names* nil
  "A list of all function-caches")

(defun find-function-cache-for-name (cache-name)
  "given a name get the cache object associated with it"
  (iter (for name in *cache-names*)
    (for obj = (symbol-value name))
    (when (or (eql name cache-name) ;; check the cache name
              (eql (name obj) cache-name)) ;; check the fn name
      (return obj))))

(defgeneric cached-results-count (cache)
  (:documentation "A function to compute the number of results that have been
   cached. DOES NOT CHECK to see if the entries are expired")
  (:method ((hash hash-table))
    (hash-table-count hash))
  (:method ((res list))
    (length res))
  (:method ((cache function-cache))
    (cached-results-count (cached-results cache)))
  (:method ((cache single-cell-function-cache))
    (if (cdr (cached-results cache)) 1 0))
  (:method ((cache thunk-cache))
    (if (cddr (cached-results cache)) 1 0)))

(defgeneric partial-argument-match? (cache cached-key to-match
                                     &key test)
  (:documentation "Trys to see if the cache-key matches the to-match partial
   key passed in.

   The basic implementation is to go through the cache-keys and match in
   order, skipping to-match component that is function-cache:dont-care")
  (:method ((cache hash-table-function-cache) cached-key to-match
            &key (test (let ((hash (cached-results cache)))
                         (when hash (hash-table-test hash)))))
    (when test
      (setf to-match (alexandria:ensure-list to-match))
      (iter
        (for k in cached-key)
        (for m = (or (pop to-match) 'dont-care))
        (unless (eql m 'dont-care)
          ;; TODO: should this recursivly call if k is a list?
          (always (funcall test k m)))
        (while to-match)))))

(defgeneric clear-cache-partial-arguments (cache to-match)
  (:documentation "This function will go through the cached-results removing
    keys that partially match the to-match list.

    This is used to clear the cache of shared? caches, but is also useful in
    other cases, where we need to clear cache for some subset of the
    arguments (eg: a cached funcall might wish to clear the cache of a
    specific funcalled function).

    Matches arguments for those provided. Anything not provided is considered
    function-cache:dont-care.  Anything specified as function-cache:dont-care
    is not used to determine if there is a match
   ")
  (:method ((cache hash-table-function-cache) to-match)
    (let* ((hash (cached-results cache))
           (test (when hash (hash-table-test hash))))
      (setf to-match (alexandria:ensure-list to-match))
      (iter (for (key value) in-hashtable hash)
        (when (partial-argument-match? cache key to-match :test test)
          (collect key into keys-to-rem))
        (finally (iter (for key in keys-to-rem)
                   (remhash key hash)))))))

(defgeneric clear-cache (cache &optional args)
  (:documentation "Clears a given cache")
  (:method ((cache-name symbol) &optional (args nil args-input?))
    (let ((obj (find-function-cache-for-name cache-name)))
      ;; only call with args if we called this with args
      ;; otherwise there is no determination between (eg: &rest called with nil args
      ;; and not calling with args)
      (if args-input?
        (clear-cache obj args)
        (clear-cache obj))))
  (:method ((cache function-cache) &optional args)
    (declare (ignore args))
    (setf (cached-results cache) nil))
  (:method ((cache hash-table-function-cache)
            &optional (args nil args-input?)
            &aux
            (name (name cache))
            (hash (cached-results cache))
            (shared-results? (shared-results? cache)))
    (setf args (ensure-list args))
    ;; there was no cache, so there can be no results to clear
    (when hash
      (cond (args-input?
             (remhash (compute-cache-key cache args) hash))
            ((not shared-results?)
             ;; clear the whole hash, as they didnt specify args and
             ;; it doesnt share storage
             (clrhash hash))
            ;; we need to sort out which keys to remove based on our name
            (shared-results?
             (clear-cache-partial-arguments cache name))))))

(defun do-caches (fn &key package)
  "Iterate through caches calling fn on each matching cache"
  (when package (setf package (find-package package)))
  (iter (for n in *cache-names*)
    (when (or (null package) (eql (symbol-package n) package))
      (funcall fn (symbol-value n)))))

(defun clear-cache-all-function-caches (&optional package)
  "Clear all the packages we know about. If there is a package mentioned,
   clear only those caches whose names are in that package"
  (do-caches #'clear-cache :package package))

(defgeneric purge-cache (cache)
  (:documentation "A function that will remove expired entries from the cache,
  allowing them to be garbage collected")
  ;; only actually purge if there is the possibility of removing entries
  (:method :around ((cache function-cache))
    (when (timeout cache)
      (call-next-method)))
  (:method ((cache-name symbol))
    (purge-cache (find-function-cache-for-name cache-name)))
  (:method ((cache single-cell-function-cache))
    (let* ((res (cached-results cache))
           (cached-at (cddr res)))
      (when (expired? cache cached-at)
        (clear-cache cache))))
  (:method ((cache thunk-cache))
    (let* ((cached-at (cdr (cached-results cache))))
      (when (expired? cache cached-at)
        (clear-cache cache))))
  (:method ((cache hash-table-function-cache)
            &aux (hash (cached-results cache)))
    (when hash
      (iter (for (key value) in-hashtable hash)
        (for (rtn . cached-at) = value)
        (when (expired? cache cached-at)
          (collect key into to-remove))
        (finally (iter (for rem in to-remove)
                   (remhash rem hash)))))))

(defun purge-all-caches (&optional package)
  "Call purge on all matching cache objects.  If package is provided, purge
   only caches located within that package"
  (do-caches #'purge-cache :package package))

(defun %ensure-unquoted (thing)
  (etypecase thing
    (null nil)
    (symbol thing)
    (list (when (eql 'quote (first thing))
            (second thing)))))

(defgeneric default-cache-class (symbol lambda-list)
  (:documentation "A function that takes symbol lambda-list and perhaps a cache-class")
  (:method (symbol lambda-list)
    (destructuring-bind (fn-name &key cache-class &allow-other-keys)
        (ensure-list symbol)
      (declare (ignore fn-name))
      (setf cache-class (%ensure-unquoted cache-class))
      (cond
        (cache-class cache-class)
        ((null lambda-list) 'thunk-cache)
        (t 'hash-table-function-cache)))))

(defun %call-list-for-lambda-list (lambda-list)
  "Turns a lambda list into a list that can be applied to functions of that lambda list"
  (multiple-value-bind (args optional rest keys)
      (alexandria:parse-ordinary-lambda-list lambda-list)
    (let* ((call-list (append args
                              (mapcar #'first optional)
                              (mapcan #'first keys)
                              ))
           (call-list (cond
                        ((and call-list rest)
                         `(list* ,@call-list ,rest))
                        (call-list `(list ,@call-list))
                        (rest rest))))
      call-list)))

(defmacro defcached (symbol lambda-list &body body)
  "Creates a cached function named SYMBOL and a cache object named *{FN-NAME}-CACHE*
   SYMBOL can also be a list (FN-NAME &rest CACHE-INIT-ARGS
                           &key CACHE-CLASS TABLE TIMEOUT SHARED-RESULTS?)

   TABLE - a shared cache-store to use, usually a hash-table, a function that returns
     a hashtable, or a symbol whose value is a hash-table
   TIMEOUT - how long entries in the cache should be considered valid for
   CACHE-CLASS - controls what cache class will be instantiated (uses
     default-cache-class if not provided)
   SHARED-RESULTS? - do we expect that we are sharing cache space with other things
     defaults to t if TABLE is provided
   CACHE-INIT-ARGS - any other args that should be passed to the cache
  "
  (destructuring-bind (fn-name
                       &rest cache-args
                       &key table (shared-results? nil shared-result-input?)
                       cache-class
                       &allow-other-keys)
      (ensure-list symbol)
    (declare (ignore cache-class));; handled in default-cache-class
    (remf cache-args :cache-class)
    (remf cache-args :table)
    (remf cache-args :shared-results?)
    (when (and table (not shared-result-input?))  (setf shared-results? t))
    (let* ((cache-class (default-cache-class symbol lambda-list))
           (cache (symbol-munger:english->lisp-symbol #?"*${ fn-name }-cache*"))
           (doc (when (stringp (first body)) (first body)))
           (call-list (%call-list-for-lambda-list lambda-list)))
      `(progn
        (defvar ,cache nil)
        (pushnew ',cache *cache-names*)
        (setf ,cache
         (make-instance ',cache-class
          :body-fn (lambda ,lambda-list ,@body)
          :name ',fn-name
          :lambda-list ',lambda-list
          :shared-results? ,shared-results?
          :cached-results ,table
          ,@cache-args))
        (defun ,fn-name ,lambda-list
          ,doc
          (cacher ,cache ,call-list))))))
