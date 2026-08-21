;;; reference-explorer-test.el --- Reference Explorer tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-core)

(ert-deftest reference-explorer-query-prefers-active-region ()
  (with-temp-buffer
    (insert "before selected after")
    (goto-char 8)
    (push-mark 16 t t)
    (let ((reference-explorer-query-function
           (lambda () "fallback"))
          (transient-mark-mode t))
      (should (equal (reference-explorer-query-at-point) "selected")))))

(ert-deftest reference-explorer-query-trims-properties-and-space ()
  (with-temp-buffer
    (let ((reference-explorer-query-function
           (lambda () (propertize "  dictionary  " 'face 'bold))))
      (should (equal (reference-explorer-query-at-point) "dictionary")))))

(ert-deftest reference-explorer-context-marks-automatic-point-lookup ()
  (with-temp-buffer
    (insert "dictionary")
    (goto-char 3)
    (let ((reference-explorer-query-function (lambda () "dictionary")))
      (should
       (reference-explorer-context-automatic
        (reference-explorer-context-at-point))))))

(ert-deftest reference-explorer-context-keeps-region-query-exact ()
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
    (let ((reference-explorer-query-function (lambda () "visible"))
          (reference-explorer-origin-position-function (lambda () 8)))
      (should
       (= (marker-position
           (reference-explorer-context-marker
            (reference-explorer-context-at-point)))
          8)))))

(ert-deftest reference-explorer-selects-provider-from-originating-mode ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (let* ((context (reference-explorer-context-create
                     :query "symbol" :marker (copy-marker (point))))
           (reference-explorer-provider-rules
            '((emacs-lisp-mode . (elisp-help))
              (t . (dictionary)))))
      (should (equal (reference-explorer--providers-for-context context)
                     '(elisp-help))))))

(ert-deftest reference-explorer-provider-rule-may-disable-a-mode ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (let* ((context (reference-explorer-context-create
                     :query "symbol" :marker (copy-marker (point))))
           (reference-explorer-provider-rules
            '((emacs-lisp-mode)
              (t . (lookup)))))
      (should-not (reference-explorer--providers-for-context context)))))

(ert-deftest reference-explorer-provider-rules-use-catch-all-default ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (let* ((context (reference-explorer-context-create
                     :query "symbol" :marker (copy-marker (point))))
           (reference-explorer-provider-rules
            '((text-mode . (dictionary))
              (t . (docset lookup)))))
      (should (equal (reference-explorer--providers-for-context context)
                     '(docset lookup))))))

(ert-deftest reference-explorer-falls-back-only-when-unavailable ()
  (let ((reference-explorer--providers nil)
        (reference-explorer-fallback-conditions '(unavailable))
        called)
    (reference-explorer-register-provider
     'primary
     (lambda (_context)
       (signal 'reference-explorer-provider-unavailable '("missing"))))
    (reference-explorer-register-provider
     'fallback (lambda (_context) (setq called t) 'fallback-result))
    (should
     (eq (reference-explorer--dispatch
          '(primary fallback)
          (reference-explorer-context-create :query "query"))
         'fallback-result))
    (should called)))

(ert-deftest reference-explorer-does-not-hide-provider-errors-by-default ()
  (let ((reference-explorer--providers nil)
        (reference-explorer-fallback-conditions '(unavailable))
        fallback-called)
    (reference-explorer-register-provider
     'broken (lambda (_context) (error "broken provider")))
    (reference-explorer-register-provider
     'fallback (lambda (_context) (setq fallback-called t)))
    (should-error
     (reference-explorer--dispatch
      '(broken fallback)
      (reference-explorer-context-create :query "query"))
     :type 'error)
    (should-not fallback-called)))

(ert-deftest reference-explorer-can-disable-unavailable-fallback ()
  (let ((reference-explorer--providers nil)
        (reference-explorer-fallback-conditions nil)
        fallback-called)
    (reference-explorer-register-provider
     'missing
     (lambda (_context)
       (signal 'reference-explorer-provider-unavailable '("missing"))))
    (reference-explorer-register-provider
     'fallback (lambda (_context) (setq fallback-called t)))
    (should-error
     (reference-explorer--dispatch
      '(missing fallback)
      (reference-explorer-context-create :query "query"))
     :type 'reference-explorer-provider-unavailable)
    (should-not fallback-called)))

(provide 'reference-explorer-test)
;;; reference-explorer-test.el ends here
