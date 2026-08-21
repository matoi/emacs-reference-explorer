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
     :candidate
     (lambda (value _context)
       (reference-explorer-candidate-create
        :label (downcase value) :annotation (concat "from " value)))
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
      (should (reference-explorer-candidate-p result))
      (should (eq (reference-explorer-candidate-source result) 'example))
      (should (equal (reference-explorer-candidate-label result) "entry"))
      (should (equal (reference-explorer-candidate-annotation result)
                     "from ENTRY"))
      (let ((buffer (reference-explorer-candidate-render
                     result " *Source Protocol Test*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal (buffer-string) "ENTRY")))
          (kill-buffer buffer))))))

(ert-deftest reference-explorer-source-protocol-requires-search-operation ()
  (let ((reference-explorer--sources nil))
    (should-error
     (reference-explorer-register-source
      'incomplete :candidate #'identity))))

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
  (let ((reference-explorer--sources nil)
        (fetches 0) (renders 0))
    (reference-explorer-register-source
     'lazy
     :search (lambda (_query _context _complete))
     :candidate (lambda (entry _context)
                  (reference-explorer-candidate-create :label entry))
     :fetch (lambda (entry)
              (cl-incf fetches)
              (concat "body:" entry))
     :render (lambda (content buffer-name)
               (cl-incf renders)
               (let ((buffer (get-buffer-create buffer-name)))
                 (with-current-buffer buffer
                   (erase-buffer)
                   (insert content))
                 buffer)))
    (let* ((result (reference-explorer-source-make-candidate
                    'lazy "id" nil))
           (buffer (reference-explorer-candidate-render
                    result " *Source Fetch Test*")))
      (unwind-protect
          (with-current-buffer buffer
            (should (equal (buffer-string) "body:id")))
        (kill-buffer buffer)))
    (should (= fetches 1))
    (should (= renders 1))))

(ert-deftest reference-explorer-source-declares-candidate-commit-action ()
  (let ((reference-explorer--sources nil)
        received)
    (reference-explorer-register-source
     'action
     :search (lambda (_query _context _complete))
     :candidate (lambda (value _context)
                  (reference-explorer-candidate-create :label value))
     :commit (lambda (candidate context)
               (setq received (list candidate context))))
    (let ((candidate (reference-explorer-source-make-candidate
                      'action "candidate" nil)))
      (reference-explorer-candidate-commit candidate 'context)
      (should (eq (car received) candidate))
      (should (eq (cadr received) 'context)))))

(ert-deftest reference-explorer-source-may-disable-commit ()
  (let ((reference-explorer--sources nil))
    (reference-explorer-register-source
     'display-only
     :search (lambda (_query _context _complete))
     :candidate (lambda (value _context)
                  (reference-explorer-candidate-create :label value))
     :commit nil)
    (should-not
     (reference-explorer-candidate-commit
      (reference-explorer-source-make-candidate 'display-only "candidate" nil)
      nil))))

(ert-deftest reference-explorer-source-search-does-not-fetch-or-render ()
  (let ((reference-explorer--sources nil) fetched rendered outcome)
    (reference-explorer-register-source
     'lazy-search
     :search (lambda (_query _context complete)
               (funcall complete
                        (reference-explorer-search-outcome-create
                         :status 'matched :entries '("id"))))
     :candidate (lambda (_value _context)
                  (reference-explorer-candidate-create :label "label"))
     :fetch (lambda (_value) (setq fetched t))
     :render (lambda (_content _buffer-name) (setq rendered t)))
    (reference-explorer-source-search
     'lazy-search "query" nil (lambda (value) (setq outcome value)))
    (should (reference-explorer-candidate-p
             (car (reference-explorer-search-outcome-entries outcome))))
    (should-not fetched)
    (should-not rendered)))

(ert-deftest reference-explorer-source-preview-policy-can-be-overridden ()
  (let ((reference-explorer--sources nil)
        (reference-explorer-source-preview-overrides nil))
    (reference-explorer-register-source
     'previewable
     :search (lambda (_query _context _complete))
     :preview t)
    (should (reference-explorer-source-preview-p 'previewable))
    (let ((reference-explorer-source-preview-overrides
           '((previewable . nil))))
      (should-not (reference-explorer-source-preview-p 'previewable)))))

(provide 'reference-explorer-source-test)
;;; reference-explorer-source-test.el ends here
