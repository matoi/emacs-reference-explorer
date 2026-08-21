;;; reference-explorer-source-thesaurus.el --- Asynchronous thesaurus backend -*- lexical-binding: t -*-

;;; Commentary:

;; Retrieve thesaurus candidates without imposing a presentation layer.  The
;; default backend retrieves data from the Power Thesaurus website
;; (https://www.powerthesaurus.org/) through its GraphQL endpoint at
;; https://api.powerthesaurus.org.  This is an independent integration and is
;; not affiliated with or endorsed by Power Thesaurus.  Use of the service is
;; subject to its terms at https://www.powerthesaurus.org/_terms_conditions.
;; The public fetch function is replaceable, and the rest of the reference UI
;; does not depend on the service's data representation.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'reference-explorer-source)
(require 'subr-x)
(require 'url)

(defgroup reference-explorer-source-thesaurus nil
  "Retrieve thesaurus candidates for reference interfaces."
  :group 'applications)

(defcustom reference-explorer-source-thesaurus-api-url "https://api.powerthesaurus.org"
  "Power Thesaurus GraphQL endpoint used by the default backend."
  :type 'string
  :group 'reference-explorer-source-thesaurus)

(defcustom reference-explorer-source-thesaurus-fetch-function
  #'reference-explorer-source-thesaurus-powerthesaurus-fetch
  "Function used to retrieve thesaurus candidates.
The function receives QUERY, TYPE, SUCCESS and ERROR.  SUCCESS is called with
a list of `reference-explorer-source-thesaurus-result' objects.  ERROR is called with a human
readable string.  A backend must not perform speculative requests: retrieval
starts only when this function is called explicitly."
  :type 'function
  :group 'reference-explorer-source-thesaurus)

(defcustom reference-explorer-source-thesaurus-cache-limit 256
  "Maximum number of completed thesaurus searches retained in memory."
  :type 'integer
  :group 'reference-explorer-source-thesaurus)

(cl-defstruct (reference-explorer-source-thesaurus-result
               (:constructor reference-explorer-source-thesaurus-result-create))
  "One thesaurus candidate returned by a backend."
  term
  relations
  rating
  votes
  source)

(defvar reference-explorer-source-thesaurus--term-id-cache (make-hash-table :test #'equal)
  "Power Thesaurus term IDs cached by normalized query.")

(defvar reference-explorer-source-thesaurus--result-cache (make-hash-table :test #'equal)
  "Completed result lists cached by normalized query and relation type.")

(defvar reference-explorer-source-thesaurus--pending (make-hash-table :test #'equal)
  "Callbacks waiting for an in-flight query.")

(defconst reference-explorer-source-thesaurus--search-query
  "query SEARCH($query: String!) {
  search(query: $query) {
    terms { id name }
  }
}"
  "GraphQL query resolving text to a Power Thesaurus term ID.")

(defconst reference-explorer-source-thesaurus--relations-query
  "query THESAURUS($termID: ID!, $type: List!, $sort: ThesaurusSorting!) {
  thesauruses(termId: $termID, sort: $sort, list: $type) {
    edges {
      node {
        targetTerm { name }
        relations
        rating
        votes
      }
    }
  }
}"
  "GraphQL query retrieving one relation list for a term ID.")

(defun reference-explorer-source-thesaurus--normalize-query (query)
  "Return normalized cache and request key for QUERY."
  (downcase (string-trim (substring-no-properties query))))

(defun reference-explorer-source-thesaurus--type-name (type)
  "Return the Power Thesaurus relation name for TYPE."
  (pcase type
    ('synonyms "SYNONYM")
    ('antonyms "ANTONYM")
    ('related "RELATED")
    (_ (error "Unsupported thesaurus query type: %s" type))))

(defun reference-explorer-source-thesaurus-clear-cache ()
  "Forget all completed Power Thesaurus lookups."
  (interactive)
  (clrhash reference-explorer-source-thesaurus--term-id-cache)
  (clrhash reference-explorer-source-thesaurus--result-cache))

(defun reference-explorer-source-thesaurus--trim-cache (table)
  "Clear TABLE after it grows beyond the configured cache limit."
  (when (> (hash-table-count table) reference-explorer-source-thesaurus-cache-limit)
    (clrhash table)))

(defun reference-explorer-source-thesaurus--alist-get-in (object path)
  "Return the value in nested alist OBJECT at PATH."
  (dolist (key path object)
    (setq object
          (and (listp object)
               (if (integerp key)
                   (nth key object)
                 (alist-get key object))))))

(defun reference-explorer-source-thesaurus--response-error (response)
  "Return a readable GraphQL error from RESPONSE, or nil."
  (when-let ((errors (alist-get 'errors response)))
    (or (alist-get 'message (car errors))
        "Power Thesaurus returned an unspecified GraphQL error")))

(defun reference-explorer-source-thesaurus--post (variables query success failure)
  "POST GraphQL QUERY with VARIABLES, then call SUCCESS or FAILURE."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data
         (encode-coding-string
          (json-serialize `((variables . ,variables) (query . ,query)))
          'utf-8)))
    (url-retrieve
     reference-explorer-source-thesaurus-api-url
     (lambda (status)
       (let ((buffer (current-buffer)))
         (unwind-protect
             (condition-case error-data
                 (if-let ((network-error (plist-get status :error)))
                     (funcall failure (format "Power Thesaurus request failed: %s"
                                              network-error))
                   (goto-char (point-min))
                   (unless (re-search-forward "\r?\n\r?\n" nil t)
                     (error "Malformed HTTP response"))
                   (let* ((response
                           (json-parse-buffer
                            :object-type 'alist :array-type 'list
                            :null-object nil :false-object nil))
                          (graphql-error
                           (reference-explorer-source-thesaurus--response-error response)))
                     (if graphql-error
                         (funcall failure graphql-error)
                       (funcall success response))))
               (error
                (funcall failure (error-message-string error-data))))
           (when (buffer-live-p buffer)
             (kill-buffer buffer)))))
     nil t t)))

(defun reference-explorer-source-thesaurus--request-term-id (query success failure)
  "Resolve QUERY and call SUCCESS with its term ID, or FAILURE on error."
  (if-let ((cached (gethash query reference-explorer-source-thesaurus--term-id-cache)))
      (funcall success cached)
    (reference-explorer-source-thesaurus--post
     `((query . ,query))
     reference-explorer-source-thesaurus--search-query
     (lambda (response)
       (let ((term-id
              (reference-explorer-source-thesaurus--alist-get-in
               response '(data search terms 0 id))))
         (if (null term-id)
             (funcall success nil)
           (reference-explorer-source-thesaurus--trim-cache
            reference-explorer-source-thesaurus--term-id-cache)
           (puthash query term-id reference-explorer-source-thesaurus--term-id-cache)
           (funcall success term-id))))
     failure)))

(defun reference-explorer-source-thesaurus--parse-results (response)
  "Return normalized thesaurus candidates from GraphQL RESPONSE."
  (cl-loop
   for edge in (reference-explorer-source-thesaurus--alist-get-in
                response '(data thesauruses edges))
   for node = (alist-get 'node edge)
   for term = (reference-explorer-source-thesaurus--alist-get-in node '(targetTerm name))
   when (and (stringp term) (not (string-empty-p term)))
   collect
   (reference-explorer-source-thesaurus-result-create
    :term term
    :relations (alist-get 'relations node)
    :rating (alist-get 'rating node)
    :votes (alist-get 'votes node)
    :source 'powerthesaurus)))

(defun reference-explorer-source-thesaurus--finish (key results)
  "Cache RESULTS for KEY and notify all waiting callbacks."
  (reference-explorer-source-thesaurus--trim-cache reference-explorer-source-thesaurus--result-cache)
  (puthash key (cons 'results results) reference-explorer-source-thesaurus--result-cache)
  (let ((waiters (prog1 (gethash key reference-explorer-source-thesaurus--pending)
                   (remhash key reference-explorer-source-thesaurus--pending))))
    (dolist (waiter (nreverse waiters))
      (funcall (car waiter) results))))

(defun reference-explorer-source-thesaurus--fail (key message)
  "Notify callbacks waiting for KEY that retrieval failed with MESSAGE."
  (let ((waiters (prog1 (gethash key reference-explorer-source-thesaurus--pending)
                   (remhash key reference-explorer-source-thesaurus--pending))))
    (dolist (waiter (nreverse waiters))
      (funcall (cdr waiter) message))))

(defun reference-explorer-source-thesaurus-powerthesaurus-fetch
    (query type success failure)
  "Fetch QUERY relations of TYPE, calling SUCCESS or FAILURE.
The first uncached search makes exactly two requests: one for the term ID and
one for the complete relation list.  Concurrent identical searches share the
same requests.  Cached searches make no request."
  (let* ((query (reference-explorer-source-thesaurus--normalize-query query))
         (key (list query type))
         (cached (gethash key reference-explorer-source-thesaurus--result-cache 'missing)))
    (cond
     ((string-empty-p query)
      (funcall success nil))
     ((not (eq cached 'missing))
      (funcall success (cdr cached)))
     ((gethash key reference-explorer-source-thesaurus--pending)
      (push (cons success failure)
            (gethash key reference-explorer-source-thesaurus--pending)))
     (t
      (puthash key (list (cons success failure))
               reference-explorer-source-thesaurus--pending)
      (reference-explorer-source-thesaurus--request-term-id
       query
       (lambda (term-id)
         (if (null term-id)
             (reference-explorer-source-thesaurus--finish key nil)
           (reference-explorer-source-thesaurus--post
            `((type . ,(reference-explorer-source-thesaurus--type-name type))
              (termID . ,term-id)
              (sort . ((field . "RATING") (direction . "DESC"))))
            reference-explorer-source-thesaurus--relations-query
            (lambda (response)
              (reference-explorer-source-thesaurus--finish
               key (reference-explorer-source-thesaurus--parse-results response)))
            (lambda (message)
              (reference-explorer-source-thesaurus--fail key message)))))
       (lambda (message)
         (reference-explorer-source-thesaurus--fail key message)))))))

(defun reference-explorer-source-thesaurus-fetch (query type success &optional failure)
  "Fetch QUERY candidates of TYPE and call SUCCESS asynchronously.
FAILURE defaults to reporting a user-facing message."
  (funcall reference-explorer-source-thesaurus-fetch-function
           query type success
           (or failure
               (lambda (message)
                 (message "Thesaurus: %s" message)))))

(defun reference-explorer-source-thesaurus-protocol-search
    (query _context complete)
  "Search synonyms for QUERY, then call COMPLETE with its outcome."
  (reference-explorer-source-thesaurus-fetch
   query 'synonyms
   (lambda (entries)
     (funcall complete
              (reference-explorer-search-outcome-create
               :status (if entries 'matched 'no-match)
               :entries entries)))
   (lambda (message)
     (funcall complete
              (reference-explorer-search-outcome-create
               :status 'failed :message message)))))

(defun reference-explorer-source-thesaurus-protocol-render (result buffer-name)
  "Render thesaurus RESULT in BUFFER-NAME and return its buffer."
  (let ((buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (reference-explorer-source-thesaurus-result-term result))
        (when-let ((relations
                    (reference-explorer-source-thesaurus-result-relations result)))
          (insert "\n\n" (string-join relations ", ")))
        (special-mode)))
    buffer))

(reference-explorer-register-source
 'thesaurus
 :title "Power Thesaurus"
 :search #'reference-explorer-source-thesaurus-protocol-search
 :label #'reference-explorer-source-thesaurus-result-term
 :render #'reference-explorer-source-thesaurus-protocol-render)

(provide 'reference-explorer-source-thesaurus)
;;; reference-explorer-source-thesaurus.el ends here
