;;; reference-explorer-provider-monokakido-test.el --- Monokakido provider tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-provider-monokakido)

(ert-deftest reference-explorer-provider-monokakido-encodes-query ()
  (let ((reference-explorer-provider-monokakido-category nil)
        (reference-explorer-provider-monokakido-scope nil))
    (should
     (equal
      (reference-explorer-provider-monokakido--url "説明 文&語")
      (concat "mkdictionaries:///?text="
              "%E8%AA%AC%E6%98%8E%20%E6%96%87%26%E8%AA%9E")))))

(ert-deftest reference-explorer-provider-monokakido-includes-search-options ()
  (let ((reference-explorer-provider-monokakido-category "ja")
        (reference-explorer-provider-monokakido-scope "example"))
    (should
     (equal
      (reference-explorer-provider-monokakido--url "機会")
      (concat "mkdictionaries:///?text=%E6%A9%9F%E4%BC%9A"
              "&category=ja&scope=example")))))

(ert-deftest reference-explorer-provider-monokakido-opens-url-without-shell ()
  (let ((context (reference-explorer-context-create :query "機会"))
        called)
    (cl-letf (((symbol-function
                'reference-explorer-provider-monokakido-available-p)
               (lambda () t))
              ((symbol-function 'call-process)
               (lambda (&rest arguments)
                 (setq called arguments)
                 0)))
      (should (reference-explorer-provider-monokakido-display context))
      (should
       (equal called
              '("open" nil 0 nil "-u"
                "mkdictionaries:///?text=%E6%A9%9F%E4%BC%9A"))))))

(provide 'reference-explorer-provider-monokakido-test)
;;; reference-explorer-provider-monokakido-test.el ends here
