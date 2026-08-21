;;; reference-explorer-source-macos-test.el --- macOS source tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-source-macos)

(ert-deftest reference-explorer-source-macos-module-path-is-package-owned ()
  (should
   (string-suffix-p
    (concat "/site-lisp/reference-explorer/reference-explorer-source-macos-module"
            (if (boundp 'module-file-suffix) module-file-suffix ".dylib"))
    reference-explorer-source-macos-module-file)))

(ert-deftest reference-explorer-source-macos-computes-screen-baseline ()
  (with-temp-buffer
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((context
             (reference-explorer-context-create
              :query "dictionary"
              :marker (copy-marker (point))
              :window (selected-window)))
            (font-info (make-vector 14 nil)))
        (aset font-info 2 15)
        (aset font-info 8 15)
        (cl-letf (((symbol-function 'window-absolute-pixel-position)
                   (lambda (&rest _) '(30 . 40)))
                  ((symbol-function 'frame-geometry)
                   (lambda (&rest _) '((outer-position . (100 . 200)))))
                  ((symbol-function 'font-at) (lambda (&rest _) 'font))
                  ((symbol-function 'font-xlfd-name) (lambda (_) "Font"))
                  ((symbol-function 'font-info)
                   (lambda (&rest _) font-info))
                  ((symbol-function 'font-get)
                   (lambda (_font key)
                     (pcase key
                       (:family 'Test\ Font)
                       (:weight 'medium)
                       (:size 15)))))
          (should
           (equal (reference-explorer-source-macos--presentation context)
                  '((130 . 255) "Test Font" "medium" 15.0))))))))

(ert-deftest reference-explorer-source-macos-reports-success ()
  (let ((context (reference-explorer-context-create :query "dictionary"))
        called)
    (cl-letf (((symbol-function 'reference-explorer-source-macos--load-module)
               (lambda () t))
              ((symbol-function 'reference-explorer-source-macos--presentation)
               (lambda (_context) '((10 . 20) "Test Font" "medium" 15.0)))
              ((symbol-function
                'reference-explorer-source-macos-show-definition-with-font)
               (lambda (query x y family weight size)
                 (setq called (list query x y family weight size))
                 t))
              ((symbol-function 'reference-explorer-source-macos--arm-dismissal)
               #'ignore))
      (should (reference-explorer-source-macos-display context))
      (should
       (equal called '("dictionary" 10 20 "Test Font" "medium" 15.0))))))

(ert-deftest reference-explorer-source-macos-automatic-lookup-anchors-at-term-start ()
  (with-temp-buffer
    (insert "これは説明文全体です")
    (goto-char 7)
    (let ((context
           (reference-explorer-context-create
            :query "説明文全体"
            :marker (copy-marker (point))
            :window (selected-window)
            :automatic t))
          called)
      (cl-letf (((symbol-function 'reference-explorer-source-macos--load-module)
                 (lambda () t))
                ((symbol-function 'reference-explorer-source-macos--presentation)
                 (lambda (refined)
                   (should
                    (= (marker-position
                        (reference-explorer-context-marker refined))
                       4))
                   '((10 . 20) "Test Font" "medium" 15.0)))
                ((symbol-function
                  'reference-explorer-source-macos-selection-at-offset)
                 (lambda (text offset)
                   (should (equal text "これは説明文全体です"))
                   (should (= offset (string-bytes "これは説明文")))
                   (list "説明文" (string-bytes "これは")
                         (string-bytes "これは説明文"))))
                ((symbol-function
                  'reference-explorer-source-macos-show-definition-with-font)
                 (lambda (term x y family weight size)
                   (setq called (list term x y family weight size))
                   t))
                ((symbol-function 'reference-explorer-source-macos--arm-dismissal)
                 #'ignore))
        (should (reference-explorer-source-macos-display context))
        (should
         (equal called '("説明文" 10 20 "Test Font" "medium" 15.0)))))))

(ert-deftest reference-explorer-source-macos-dismisses-before-next-command ()
  (let (hidden)
    (unwind-protect
        (cl-letf (((symbol-function
                    'reference-explorer-source-macos-hide-definition)
                   (lambda () (setq hidden t))))
          (reference-explorer-source-macos--arm-dismissal)
          (should
           (memq #'reference-explorer-source-macos--dismiss-before-command
                 pre-command-hook))
          (reference-explorer-source-macos--dismiss-before-command)
          (should hidden)
          (should-not
           (memq #'reference-explorer-source-macos--dismiss-before-command
                 pre-command-hook)))
      (remove-hook 'pre-command-hook
                   #'reference-explorer-source-macos--dismiss-before-command))))

(ert-deftest reference-explorer-source-macos-origin-offset-counts-utf8-bytes ()
  (with-temp-buffer
    (insert "前置き dictionary 後続")
    (search-backward "dictionary")
    (let ((context
           (reference-explorer-context-create
            :query "dictionary"
            :marker (copy-marker (point)))))
      (should
       (equal (reference-explorer-source-macos--text-at-origin context)
              (cons "前置き dictionary 後続"
                    (string-bytes "前置き ")))))))

(ert-deftest reference-explorer-source-macos-rejects-invisible-origin ()
  (let ((context (reference-explorer-context-create :query "dictionary")))
    (cl-letf (((symbol-function 'reference-explorer-source-macos--load-module)
               (lambda () t))
              ((symbol-function 'reference-explorer-source-macos--presentation)
               (lambda (_context) nil)))
      (should-error (reference-explorer-source-macos-display context)
                    :type 'reference-explorer-source-unavailable))))

(provide 'reference-explorer-source-macos-test)
;;; reference-explorer-source-macos-test.el ends here
