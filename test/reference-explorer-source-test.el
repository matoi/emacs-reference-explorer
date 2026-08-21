;;; reference-explorer-source-test.el --- Source protocol tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-source)

(ert-deftest reference-explorer-source-protocol-wraps-and-renders-results ()
  (let ((reference-explorer--sources nil)
        received)
    (reference-explorer-register-source
     'example
     :title "Example"
     :search (lambda (query _context complete)
               (funcall complete
                        (reference-explorer-search-outcome-create
                         :status 'matched :entries (list (upcase query)))))
     :label #'downcase
     :annotation (lambda (value _context) (concat "from " value))
     :render (lambda (value buffer-name)
               (let ((buffer (get-buffer-create buffer-name)))
                 (with-current-buffer buffer
                   (erase-buffer)
                   (insert value))
                 buffer)))
    (reference-explorer-source-search
     'example "entry" nil (lambda (outcome) (setq received outcome)))
    (should (eq (reference-explorer-search-outcome-status received) 'matched))
    (let ((result (car (reference-explorer-search-outcome-entries received))))
      (should (reference-explorer-source-result-p result))
      (should (eq (reference-explorer-source-result-source result) 'example))
      (should (equal (reference-explorer-source-result-label result) "entry"))
      (should (equal (reference-explorer-source-result-annotation result)
                     "from ENTRY"))
      (let ((buffer (reference-explorer-source-result-render
                     result " *Source Protocol Test*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal (buffer-string) "ENTRY")))
          (kill-buffer buffer))))))

(ert-deftest reference-explorer-source-protocol-requires-search-operation ()
  (let ((reference-explorer--sources nil))
    (should-error
     (reference-explorer-register-source
      'incomplete :label #'identity))))

(ert-deftest reference-explorer-source-protocol-reports-unavailable-source ()
  (let ((reference-explorer--sources nil)
        outcome)
    (reference-explorer-register-source
     'offline
     :search (lambda (_query _context _complete))
     :available-p (lambda (_context) nil))
    (reference-explorer-source-search
     'offline "entry" nil (lambda (value) (setq outcome value)))
    (should (eq (reference-explorer-search-outcome-status outcome)
                'unavailable))
    (should (string-match-p
             "unavailable"
             (reference-explorer-search-outcome-message outcome)))))

(ert-deftest reference-explorer-source-converts-selected-phrase-before-presenting ()
  (let ((reference-explorer--sources nil)
        received)
    (reference-explorer-register-source
     'converted
     :convert (lambda (phrase _context) (upcase phrase))
     :search (lambda (_query _context _complete))
     :present (lambda (context)
                (setq received
                      (list (reference-explorer-context-phrase context)
                            (reference-explorer-context-query context)))))
    (reference-explorer-run-source
     'converted
     (reference-explorer-context-create :phrase "entry" :query "entry"))
    (should (equal received '("entry" "ENTRY")))))

(ert-deftest reference-explorer-source-allows-delegated-search-without-renderer ()
  (let ((reference-explorer--sources nil)
        outcome)
    (reference-explorer-register-source
     'external
     :search (lambda (_query _context complete)
               (funcall complete
                        (reference-explorer-search-outcome-create
                         :status 'delegated))))
    (reference-explorer-source-search
     'external "entry" nil (lambda (value) (setq outcome value)))
    (should (eq (reference-explorer-search-outcome-status outcome)
                'delegated))))

(ert-deftest reference-explorer-source-fetches-content-before-rendering ()
  (let ((reference-explorer--sources nil))
    (reference-explorer-register-source
     'lazy
     :search (lambda (_query _context _complete))
     :fetch (lambda (entry) (concat "body:" entry))
     :label #'identity
     :render (lambda (content buffer-name)
               (let ((buffer (get-buffer-create buffer-name)))
                 (with-current-buffer buffer
                   (erase-buffer)
                   (insert content))
                 buffer)))
    (let* ((result (reference-explorer-source-result-create
                    :source 'lazy :value "id"))
           (buffer (reference-explorer-source-result-render
                    result " *Source Fetch Test*")))
      (unwind-protect
          (with-current-buffer buffer
            (should (equal (buffer-string) "body:id")))
        (kill-buffer buffer)))))

(provide 'reference-explorer-source-test)
;;; reference-explorer-source-test.el ends here
