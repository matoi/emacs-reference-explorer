;;; reference-explorer-thesaurus.el --- Asynchronous thesaurus backend -*- lexical-binding: t -*-

;;; Commentary:

;; Retrieve thesaurus candidates without imposing a presentation layer.  The
;; default backend uses PowerThesaurus's GraphQL service, but the public fetch
;; function is replaceable and the rest of the reference UI does not depend on
;; the service's data representation.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)

(defgroup reference-explorer-thesaurus nil
  "Retrieve thesaurus candidates for reference interfaces."
  :group 'applications)

(defcustom reference-explorer-thesaurus-api-url "https://api.powerthesaurus.org"
  "GraphQL endpoint used by the default thesaurus backend."
  :type 'string
  :group 'reference-explorer-thesaurus)

(defcustom reference-explorer-thesaurus-fetch-function
  #'reference-explorer-thesaurus-powerthesaurus-fetch
  "Function used to retrieve thesaurus candidates.
The function receives QUERY, TYPE, SUCCESS and ERROR.  SUCCESS is called with
a list of `reference-explorer-thesaurus-result' objects.  ERROR is called with a human
readable string.  A backend must not perform speculative requests: retrieval
starts only when this function is called explicitly."
  :type 'function
  :group 'reference-explorer-thesaurus)

(defcustom reference-explorer-thesaurus-cache-limit 256
  "Maximum number of completed thesaurus searches retained in memory."
  :type 'integer
  :group 'reference-explorer-thesaurus)

(cl-defstruct (reference-explorer-thesaurus-result
               (:constructor reference-explorer-thesaurus-result-create))
  "One thesaurus candidate returned by a backend."
  term
  relations
  rating
  votes
  source)

(defvar reference-explorer-thesaurus--term-id-cache (make-hash-table :test #'equal)
  "PowerThesaurus term IDs cached by normalized query.")

(defvar reference-explorer-thesaurus--result-cache (make-hash-table :test #'equal)
  "Completed result lists cached by normalized query and relation type.")

(defvar reference-explorer-thesaurus--pending (make-hash-table :test #'equal)
  "Callbacks waiting for an in-flight query.")

(defconst reference-explorer-thesaurus--search-query
  "query SEARCH($query: String!) {
  search(query: $query) {
    terms { id name }
  }
}"
  "GraphQL query resolving text to a PowerThesaurus term ID.")

(defconst reference-explorer-thesaurus--relations-query
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

(defun reference-explorer-thesaurus--normalize-query (query)
  "Return normalized cache and request key for QUERY."
  (downcase (string-trim (substring-no-properties query))))

(defun reference-explorer-thesaurus--type-name (type)
  "Return the PowerThesaurus relation name for TYPE."
  (pcase type
    ('synonyms "SYNONYM")
    ('antonyms "ANTONYM")
    ('related "RELATED")
    (_ (error "Unsupported thesaurus query type: %s" type))))

(defun reference-explorer-thesaurus-clear-cache ()
  "Forget all completed PowerThesaurus lookups."
  (interactive)
  (clrhash reference-explorer-thesaurus--term-id-cache)
  (clrhash reference-explorer-thesaurus--result-cache))

(defun reference-explorer-thesaurus--trim-cache (table)
  "Clear TABLE after it grows beyond the configured cache limit."
  (when (> (hash-table-count table) reference-explorer-thesaurus-cache-limit)
    (clrhash table)))

(defun reference-explorer-thesaurus--alist-get-in (object path)
  "Return the value in nested alist OBJECT at PATH."
  (dolist (key path object)
    (setq object
          (and (listp object)
               (if (integerp key)
                   (nth key object)
                 (alist-get key object))))))

(defun reference-explorer-thesaurus--response-error (response)
  "Return a readable GraphQL error from RESPONSE, or nil."
  (when-let ((errors (alist-get 'errors response)))
    (or (alist-get 'message (car errors))
        "PowerThesaurus returned an unspecified GraphQL error")))

(defun reference-explorer-thesaurus--post (variables query success failure)
  "POST GraphQL QUERY with VARIABLES, then call SUCCESS or FAILURE."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data
         (encode-coding-string
          (json-serialize `((variables . ,variables) (query . ,query)))
          'utf-8)))
    (url-retrieve
     reference-explorer-thesaurus-api-url
     (lambda (status)
       (let ((buffer (current-buffer)))
         (unwind-protect
             (condition-case error-data
                 (if-let ((network-error (plist-get status :error)))
                     (funcall failure (format "PowerThesaurus request failed: %s"
                                              network-error))
                   (goto-char (point-min))
                   (unless (re-search-forward "\r?\n\r?\n" nil t)
                     (error "Malformed HTTP response"))
                   (let* ((response
                           (json-parse-buffer
                            :object-type 'alist :array-type 'list
                            :null-object nil :false-object nil))
                          (graphql-error
                           (reference-explorer-thesaurus--response-error response)))
                     (if graphql-error
                         (funcall failure graphql-error)
                       (funcall success response))))
               (error
                (funcall failure (error-message-string error-data))))
           (when (buffer-live-p buffer)
             (kill-buffer buffer)))))
     nil t t)))

(defun reference-explorer-thesaurus--request-term-id (query success failure)
  "Resolve QUERY and call SUCCESS with its term ID, or FAILURE on error."
  (if-let ((cached (gethash query reference-explorer-thesaurus--term-id-cache)))
      (funcall success cached)
    (reference-explorer-thesaurus--post
     `((query . ,query))
     reference-explorer-thesaurus--search-query
     (lambda (response)
       (let ((term-id
              (reference-explorer-thesaurus--alist-get-in
               response '(data search terms 0 id))))
         (if (null term-id)
             (funcall success nil)
           (reference-explorer-thesaurus--trim-cache
            reference-explorer-thesaurus--term-id-cache)
           (puthash query term-id reference-explorer-thesaurus--term-id-cache)
           (funcall success term-id))))
     failure)))

(defun reference-explorer-thesaurus--parse-results (response)
  "Return normalized thesaurus candidates from GraphQL RESPONSE."
  (cl-loop
   for edge in (reference-explorer-thesaurus--alist-get-in
                response '(data thesauruses edges))
   for node = (alist-get 'node edge)
   for term = (reference-explorer-thesaurus--alist-get-in node '(targetTerm name))
   when (and (stringp term) (not (string-empty-p term)))
   collect
   (reference-explorer-thesaurus-result-create
    :term term
    :relations (alist-get 'relations node)
    :rating (alist-get 'rating node)
    :votes (alist-get 'votes node)
    :source 'powerthesaurus)))

(defun reference-explorer-thesaurus--finish (key results)
  "Cache RESULTS for KEY and notify all waiting callbacks."
  (reference-explorer-thesaurus--trim-cache reference-explorer-thesaurus--result-cache)
  (puthash key (cons 'results results) reference-explorer-thesaurus--result-cache)
  (let ((waiters (prog1 (gethash key reference-explorer-thesaurus--pending)
                   (remhash key reference-explorer-thesaurus--pending))))
    (dolist (waiter (nreverse waiters))
      (funcall (car waiter) results))))

(defun reference-explorer-thesaurus--fail (key message)
  "Notify callbacks waiting for KEY that retrieval failed with MESSAGE."
  (let ((waiters (prog1 (gethash key reference-explorer-thesaurus--pending)
                   (remhash key reference-explorer-thesaurus--pending))))
    (dolist (waiter (nreverse waiters))
      (funcall (cdr waiter) message))))

(defun reference-explorer-thesaurus-powerthesaurus-fetch
    (query type success failure)
  "Fetch QUERY relations of TYPE, calling SUCCESS or FAILURE.
The first uncached search makes exactly two requests: one for the term ID and
one for the complete relation list.  Concurrent identical searches share the
same requests.  Cached searches make no request."
  (let* ((query (reference-explorer-thesaurus--normalize-query query))
         (key (list query type))
         (cached (gethash key reference-explorer-thesaurus--result-cache 'missing)))
    (cond
     ((string-empty-p query)
      (funcall success nil))
     ((not (eq cached 'missing))
      (funcall success (cdr cached)))
     ((gethash key reference-explorer-thesaurus--pending)
      (push (cons success failure)
            (gethash key reference-explorer-thesaurus--pending)))
     (t
      (puthash key (list (cons success failure))
               reference-explorer-thesaurus--pending)
      (reference-explorer-thesaurus--request-term-id
       query
       (lambda (term-id)
         (if (null term-id)
             (reference-explorer-thesaurus--finish key nil)
           (reference-explorer-thesaurus--post
            `((type . ,(reference-explorer-thesaurus--type-name type))
              (termID . ,term-id)
              (sort . ((field . "RATING") (direction . "DESC"))))
            reference-explorer-thesaurus--relations-query
            (lambda (response)
              (reference-explorer-thesaurus--finish
               key (reference-explorer-thesaurus--parse-results response)))
            (lambda (message)
              (reference-explorer-thesaurus--fail key message)))))
       (lambda (message)
         (reference-explorer-thesaurus--fail key message)))))))

(defun reference-explorer-thesaurus-fetch (query type success &optional failure)
  "Fetch QUERY candidates of TYPE and call SUCCESS asynchronously.
FAILURE defaults to reporting a user-facing message."
  (funcall reference-explorer-thesaurus-fetch-function
           query type success
           (or failure
               (lambda (message)
                 (message "Thesaurus: %s" message)))))

(provide 'reference-explorer-thesaurus)
;;; reference-explorer-thesaurus.el ends here
