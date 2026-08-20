;;; reference-explorer-thesaurus-test.el --- Thesaurus backend tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-thesaurus)

(defmacro reference-explorer-thesaurus-test--with-empty-state (&rest body)
  "Run BODY with isolated backend caches and pending requests."
  (declare (indent 0) (debug t))
  `(let ((reference-explorer-thesaurus--term-id-cache
          (make-hash-table :test #'equal))
         (reference-explorer-thesaurus--result-cache
          (make-hash-table :test #'equal))
         (reference-explorer-thesaurus--pending
          (make-hash-table :test #'equal)))
     ,@body))

(ert-deftest reference-explorer-thesaurus-normalizes-cache-query ()
  (should (equal (reference-explorer-thesaurus--normalize-query "  Example  ")
                 "example")))

(ert-deftest reference-explorer-thesaurus-parses-relation-results ()
  (let* ((response
          '((data
             (thesauruses
              (edges
               ((node
                 (targetTerm (name . "sample"))
                 (relations . ["synonym"])
                 (rating . 91)
                 (votes . 12))))))))
         (result (car (reference-explorer-thesaurus--parse-results response))))
    (should (equal (reference-explorer-thesaurus-result-term result) "sample"))
    (should (= (reference-explorer-thesaurus-result-rating result) 91))
    (should (= (reference-explorer-thesaurus-result-votes result) 12))))

(ert-deftest reference-explorer-thesaurus-uncached-search-makes-two-requests ()
  (reference-explorer-thesaurus-test--with-empty-state
    (let ((requests 0)
          relation-variables
          received)
      (cl-letf
          (((symbol-function 'reference-explorer-thesaurus--post)
            (lambda (variables _query success _failure)
              (cl-incf requests)
              (when (= requests 2)
                (setq relation-variables variables))
              (funcall
               success
               (if (= requests 1)
                   '((data (search (terms ((id . "term-1")
                                            (name . "example"))))))
                 '((data
                    (thesauruses
                     (edges
                      ((node
                        (targetTerm (name . "sample"))
                        (rating . 10)
                        (votes . 2))))))))))))
        (reference-explorer-thesaurus-powerthesaurus-fetch
         "example" 'synonyms
         (lambda (results) (setq received results))
         #'ert-fail))
      (should (= requests 2))
      (should (equal (alist-get 'type relation-variables) "SYNONYM"))
      (should (equal (mapcar #'reference-explorer-thesaurus-result-term received)
                     '("sample"))))))

(ert-deftest reference-explorer-thesaurus-completed-search-is-cached ()
  (reference-explorer-thesaurus-test--with-empty-state
    (let ((requests 0)
          first second)
      (cl-letf
          (((symbol-function 'reference-explorer-thesaurus--post)
            (lambda (_variables _query success _failure)
              (cl-incf requests)
              (funcall
               success
               (if (= requests 1)
                   '((data (search (terms ((id . "term-1"))))))
                 '((data
                    (thesauruses
                     (edges
                      ((node (targetTerm (name . "sample")))))))))))))
        (reference-explorer-thesaurus-powerthesaurus-fetch
         "example" 'synonyms (lambda (results) (setq first results))
         #'ert-fail)
        (reference-explorer-thesaurus-powerthesaurus-fetch
         "Example" 'synonyms (lambda (results) (setq second results))
         #'ert-fail))
      (should (= requests 2))
      (should (eq first second)))))

(ert-deftest reference-explorer-thesaurus-concurrent-search-shares-requests ()
  (reference-explorer-thesaurus-test--with-empty-state
    (let ((requests 0)
          callbacks
          first second)
      (cl-letf
          (((symbol-function 'reference-explorer-thesaurus--post)
            (lambda (_variables _query success _failure)
              (cl-incf requests)
              (push success callbacks))))
        (reference-explorer-thesaurus-powerthesaurus-fetch
         "example" 'synonyms (lambda (results) (setq first results))
         #'ert-fail)
        (reference-explorer-thesaurus-powerthesaurus-fetch
         "example" 'synonyms (lambda (results) (setq second results))
         #'ert-fail)
        (should (= requests 1))
        (funcall (pop callbacks)
                 '((data (search (terms ((id . "term-1")))))))
        (should (= requests 2))
        (funcall (pop callbacks)
                 '((data
                    (thesauruses
                     (edges
                      ((node (targetTerm (name . "sample"))))))))))
      (should (equal (mapcar #'reference-explorer-thesaurus-result-term first)
                     '("sample")))
      (should (equal (mapcar #'reference-explorer-thesaurus-result-term second)
                     '("sample"))))))

(ert-deftest reference-explorer-thesaurus-reuses-term-id-across-relation-types ()
  (reference-explorer-thesaurus-test--with-empty-state
    (let ((requests 0))
      (cl-letf
          (((symbol-function 'reference-explorer-thesaurus--post)
            (lambda (_variables _query success _failure)
              (cl-incf requests)
              (funcall
               success
               (if (= requests 1)
                   '((data (search (terms ((id . "term-1"))))))
                 '((data (thesauruses (edges)))))))))
        (reference-explorer-thesaurus-powerthesaurus-fetch
         "example" 'synonyms #'ignore #'ert-fail)
        (reference-explorer-thesaurus-powerthesaurus-fetch
         "example" 'antonyms #'ignore #'ert-fail))
      ;; Two requests for the first type, then only the relation request for
      ;; the second type because the term ID is already known.
      (should (= requests 3)))))

(provide 'reference-explorer-thesaurus-test)
;;; reference-explorer-thesaurus-test.el ends here
