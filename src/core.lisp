(in-package :quickdocs-parser)

;;; Special variables

(defvar *store-form* nil
  "Whether or not to store, inside a node, the form it was parsed from.")

;;; Load-bearing hacks

(defmacro with-ignored-errors (() &body body)
  "Catch and ignore certain errors."
  `(handler-case
       (uiop:with-muffled-compiler-conditions ()
         (uiop:with-muffled-loader-conditions ()
           (handler-bind ((warning (lambda (c)
                                     (declare (ignore c))
                                     (muffle-warning))))
             ,@body)))
     (uiop:compile-file-error (c)
       (format *error-output* "Compilation error. Ignoring.~%  ~A~%" c))))

(defun ensure-preload (system-name)
  #+quicklisp (with-ignored-errors ()
                ;; XXX: defsystem-depends-on won't be loaded when they are only systems which aren't loaded yet.
                (let* ((system (ql-dist:find-system (string-downcase system-name)))
                       (required-systems (and system
                                              (ql-dist:required-systems system))))
                  (when required-systems
                    (ql:quickload required-systems :silent t)))
                (ql:quickload system-name :silent t))
  t)

;;; Loading systems

(defun asdf-components (comp)
  (etypecase comp
    (asdf::source-file (list comp))
    (asdf::static-file nil)
    (asdf::component
     (loop for c in (funcall
                     #+asdf3 #'asdf:component-children
                     #-asdf3 #'asdf:module-components
                     comp)
           append (asdf-components c)))))

(defun load-system (system-name)
  "Load an ASDF system by name."
  (with-ignored-errors ()
    (loop for comp in (asdf-components (asdf:find-system system-name))
          do (handler-case (typecase comp
                             (asdf:cl-source-file
                               (asdf:perform (asdf:make-operation 'asdf:compile-op) comp)
                               (asdf:perform (asdf:make-operation 'asdf:load-op) comp))
                             (asdf:c-source-file
                               (asdf:perform (asdf:make-operation 'asdf:load-op) comp)))
               (error (e)
                 (princ e *error-output*) (fresh-line *error-output*))))))

;;; Indices

(defclass package-index ()
  ((name :reader package-index-name
         :initarg :name
         :type string
         :documentation "The package's name.")
   (docstring :reader package-index-docstring
              :initarg :docstring
              :type (or null string)
              :documentation "The package's docstring.")
   (nodes :accessor package-index-nodes
          :initform (make-array 0
                                :adjustable t
                                :element-type 'documentation-node
                                :fill-pointer 0)
          :type (vector documentation-node)
          :documentation "A vector of documentation objects."))
  (:documentation "Holds the documented objects in this package."))

(defclass index ()
  ((packages :accessor index-packages
             :initform (make-array 0
                                   :adjustable t
                                   :element-type 'package-index
                                   :fill-pointer 0)
             :type (vector package-index)
             :documentation "A vector of package indices."))
  (:documentation "Holds system documentation, and the internal package indices."))

(defun add-package-index (index package-index)
  (unless (find-package-index index (package-index-name package-index))
    (vector-push-extend package-index (index-packages index))))

(defun add-node (index node)
  "Add a node to an index, finding the proper package index."
  (let* ((symbol (node-name node))
         (symbol-package (symbol-package-name symbol))
         (package-index (when symbol-package
                          (find symbol-package
                                (index-packages index)
                                :test #'equal
                                :key #'package-index-name))))
    (when package-index
      (vector-push-extend node (package-index-nodes package-index)))))

;;; Parsers

(defvar *parsers* (list)
  "A list of symbols to the functions used to parse their corresponding forms.")

(defvar *cffi-parsers* (list)
  "A list of symbols to the functions used to parse CFFI macros.")

(defmacro define-parser (name (&rest lambda-list) &body body)
  "Define a parser."
  (let ((form (gensym)))
    `(push (cons ',name (lambda (,form)
                          (destructuring-bind ,lambda-list ,form
                            ,@body)))
           *parsers*)))

(defmacro define-cffi-parser (name (&rest lambda-list) &body body)
  (check-type name keyword)
  (let ((form (gensym)))
    `(push (cons ,name (lambda (,form)
                         (destructuring-bind ,lambda-list ,form
                           ,@body)))
           *cffi-parsers*)))

(defun parse-form (form)
  "Parse a form into a node."
  (let ((first (first form)))
    (when (and (symbolp first)
               (symbol-package first)
               (string= (package-name (symbol-package first)) :cffi))
      (let ((parser (rest (assoc first *cffi-parsers* :test #'string=))))
        (when parser
          (return-from parse-form (funcall parser (rest form))))))
    (let ((parser (rest (assoc first *parsers*))))
      (when parser
        (funcall parser (rest form))))))

(defun parse-package-definition (form)
  (let ((name (princ-to-string (first form)))
        (docstring (second (find :documentation (rest form) :key #'first))))
    (make-instance 'package-index
                   :name name
                   :docstring docstring)))

(defun parse-system (index system-name)
  "Parse a system."
  (ensure-preload system-name)
  (let* ((old-macroexpander *macroexpand-hook*)
         (*macroexpand-hook*
           #'(lambda (function form environment)
               (when (listp form)
                 ;; Package nodes are special cases
                 (if (or (equal (first form) 'cl:defpackage)
                         (equal (first form) 'uiop:define-package))
                     ;; Parse the package definition, and add the new package
                     ;; index to the index
                     (let ((package-index (parse-package-definition (rest form))))
                       (add-package-index index package-index)
                       t)
                     ;; Regular node, parse it
                     (let ((node (parse-form form)))
                       (when node
                         (when *store-form*
                           (setf (node-form node) form))
                         (add-node index node))
                       t))
                 ;; Always pass the form to the old macroexpander. This ensures
                 ;; the system is loaded properly.
                 (funcall old-macroexpander
                          function
                          form
                          environment)))))
    (load-system system-name)))

;;; External interface

(defun parse (system-or-list)
  "Parse documentation from either a system name or a list of system names."
  (let ((index (make-instance 'index)))
    (if (listp system-or-list)
        (loop for name in system-or-list do
          (parse-system index name))
        (parse-system index system-or-list))
    index))

(defmacro do-packages ((package index) &body body)
  "Iterate over every package in the index."
  `(loop for ,package across (index-packages ,index) do
     ,@body))

(defmacro do-nodes ((node package-index) &body body)
  "Iterate over every node in a package index."
  `(loop for ,node across (package-index-nodes ,package-index) do
     ,@body))

(defun find-package-index (index package-name)
  "Return the package-index with that name, or NIL."
  (let ((results (remove-if-not #'(lambda (package-index)
                                    (string= (package-index-name package-index)
                                             package-name))
                                (index-packages index))))
    (if (> (length results) 0)
        (elt results 0)
        nil)))

(defun find-nodes (index package-predicate node-predicate)
  "Return a vector of nodes satisfying node-predicate, in packages satisfying
package-predicate."
  (let ((package-indices (remove-if-not package-predicate (index-packages index))))
    (apply #'concatenate
           'vector
           (loop for package-index across package-indices collecting
             (remove-if-not node-predicate (package-index-nodes package-index))))))

(defun query (index &key package-name symbol-name class)
  "Find all documentation nodes in the index matching the constraints and
returns them as a vector. package-name and symbol-name are strings, class is the
symbol of a class name. If none are found, return NIL."
  (find-nodes index
              (lambda (package-index)
                (if package-name
                    (string= package-name (package-index-name package-index))
                    t))
              (lambda (node)
                (and (if symbol-name
                         (string= symbol-name (symbol-name (node-name node)))
                         t)
                     (if class
                         (typep node class)
                         t)))))

;;; Documentation coverage

(defun coverage (index)
  "Return an alist of classes to the pair (documented nodes . total nodes of
that class."
  (let ((classes (list)))
    (do-packages (package index)
      (do-nodes (node index)
        (pushnew (class-of node) classes)))
    t))
