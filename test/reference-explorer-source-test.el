;;; reference-explorer-source-test.el --- Source protocol tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-source)

(ert-deftest reference-explorer-source-protocol-wraps-and-renders-results ()
  (let ((reference-explorer--sources nil)
        received)
    (reference-explorer-register-source
     'example
     :title "Example"
     :search (lambda (query _context success _failure)
               (funcall success (list (upcase query))))
     :label #'downcase
     :annotation (lambda (value _context) (concat "from " value))
     :render (lambda (value buffer-name)
               (let ((buffer (get-buffer-create buffer-name)))
                 (with-current-buffer buffer
                   (erase-buffer)
                   (insert value))
                 buffer)))
    (reference-explorer-source-search
     'example "entry" nil (lambda (results) (setq received results)))
    (let ((result (car received)))
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

(ert-deftest reference-explorer-source-protocol-requires-core-operations ()
  (let ((reference-explorer--sources nil))
    (should-error
     (reference-explorer-register-source
      'incomplete :search #'ignore :label #'identity))))

(ert-deftest reference-explorer-source-protocol-reports-unavailable-source ()
  (let ((reference-explorer--sources nil)
        failure)
    (reference-explorer-register-source
     'offline
     :search (lambda (_query _context _success _failure))
     :label #'identity
     :render (lambda (_value _buffer-name))
     :available-p (lambda (_context) nil))
    (reference-explorer-source-search
     'offline "entry" nil #'ignore (lambda (message) (setq failure message)))
    (should (string-match-p "unavailable" failure))))

(provide 'reference-explorer-source-test)
;;; reference-explorer-source-test.el ends here
