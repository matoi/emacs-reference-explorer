;;; reference-explorer-test.el --- Reference Explorer tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-source)

(ert-deftest reference-explorer-phrase-prefers-active-region ()
  (with-temp-buffer
    (insert "before selected after")
    (goto-char 8)
    (push-mark 16 t t)
    (let ((reference-explorer-phrase-selector-function
           (lambda () "fallback"))
          (transient-mark-mode t))
      (should (equal (reference-explorer-phrase-at-point) "selected")))))

(ert-deftest reference-explorer-phrase-trims-properties-and-space ()
  (with-temp-buffer
    (let ((reference-explorer-phrase-selector-function
           (lambda () (propertize "  dictionary  " 'face 'bold))))
      (should (equal (reference-explorer-phrase-at-point) "dictionary")))))

(ert-deftest reference-explorer-context-marks-automatic-point-lookup ()
  (with-temp-buffer
    (insert "dictionary")
    (goto-char 3)
    (let ((reference-explorer-phrase-selector-function (lambda () "dictionary")))
      (should
       (reference-explorer-context-automatic
        (reference-explorer-context-at-point))))))

(ert-deftest reference-explorer-context-keeps-region-phrase-exact ()
  (with-temp-buffer
    (insert "dictionary entry")
    (goto-char 11)
    (push-mark 1 t t)
    (let ((transient-mark-mode t))
      (let ((context (reference-explorer-context-at-point)))
        (should-not (reference-explorer-context-automatic context))
        (should
         (= (marker-position (reference-explorer-context-marker context))
            1))))))

(ert-deftest reference-explorer-context-uses-visible-origin-position ()
  (with-temp-buffer
    (insert "hidden-visible")
    (goto-char 2)
    (let ((reference-explorer-phrase-selector-function (lambda () "visible"))
          (reference-explorer-origin-position-function (lambda () 8)))
      (should
       (= (marker-position
           (reference-explorer-context-marker
            (reference-explorer-context-at-point)))
          8)))))

(ert-deftest reference-explorer-selects-source-from-originating-mode ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (let* ((context (reference-explorer-context-create
                     :query "symbol" :marker (copy-marker (point))))
           (reference-explorer-source-rules
            '((emacs-lisp-mode . (elisp-help))
              (t . (dictionary)))))
      (should (equal (reference-explorer--sources-for-context context)
                     '(elisp-help))))))

(ert-deftest reference-explorer-source-rule-may-disable-a-mode ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (let* ((context (reference-explorer-context-create
                     :query "symbol" :marker (copy-marker (point))))
           (reference-explorer-source-rules
            '((emacs-lisp-mode)
              (t . (lookup)))))
      (should-not (reference-explorer--sources-for-context context)))))

(ert-deftest reference-explorer-source-rules-use-catch-all-default ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (let* ((context (reference-explorer-context-create
                     :query "symbol" :marker (copy-marker (point))))
           (reference-explorer-source-rules
            '((text-mode . (dictionary))
              (t . (docset lookup)))))
      (should (equal (reference-explorer--sources-for-context context)
                     '(docset lookup))))))

(ert-deftest reference-explorer-falls-back-only-when-unavailable ()
  (let ((reference-explorer--sources nil)
        (reference-explorer-fallback-conditions '(unavailable))
        called)
    (reference-explorer-register-source
     'primary
     :search (lambda (_query _context _complete))
     :available-p (lambda (_context) nil))
    (reference-explorer-register-source
     'fallback
     :search (lambda (_query _context _complete))
     :present (lambda (_context) (setq called t) 'fallback-result))
    (should
     (eq (reference-explorer--dispatch
          '(primary fallback)
          (reference-explorer-context-create :query "query"))
         'fallback-result))
    (should called)))

(ert-deftest reference-explorer-does-not-hide-source-errors-by-default ()
  (let ((reference-explorer--sources nil)
        (reference-explorer-fallback-conditions '(unavailable))
        fallback-called)
    (reference-explorer-register-source
     'broken
     :search (lambda (_query _context _complete))
     :present (lambda (_context) (error "broken source")))
    (reference-explorer-register-source
     'fallback
     :search (lambda (_query _context _complete))
     :present (lambda (_context) (setq fallback-called t)))
    (should-error
     (reference-explorer--dispatch
      '(broken fallback)
      (reference-explorer-context-create :query "query"))
     :type 'error)
    (should-not fallback-called)))

(ert-deftest reference-explorer-can-disable-unavailable-fallback ()
  (let ((reference-explorer--sources nil)
        (reference-explorer-fallback-conditions nil)
        fallback-called)
    (reference-explorer-register-source
     'missing
     :search (lambda (_query _context _complete))
     :available-p (lambda (_context) nil))
    (reference-explorer-register-source
     'fallback
     :search (lambda (_query _context _complete))
     :present (lambda (_context) (setq fallback-called t)))
    (should-error
     (reference-explorer--dispatch
      '(missing fallback)
      (reference-explorer-context-create :query "query"))
     :type 'reference-explorer-source-unavailable)
    (should-not fallback-called)))

(provide 'reference-explorer-test)
;;; reference-explorer-test.el ends here
