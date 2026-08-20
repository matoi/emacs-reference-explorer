;;; reference-explorer-monokakido-test.el --- Monokakido provider tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-monokakido)

(ert-deftest reference-explorer-monokakido-encodes-query ()
  (let ((reference-explorer-monokakido-category nil)
        (reference-explorer-monokakido-scope nil))
    (should
     (equal
      (reference-explorer-monokakido--url "説明 文&語")
      (concat "mkdictionaries:///?text="
              "%E8%AA%AC%E6%98%8E%20%E6%96%87%26%E8%AA%9E")))))

(ert-deftest reference-explorer-monokakido-includes-search-options ()
  (let ((reference-explorer-monokakido-category "ja")
        (reference-explorer-monokakido-scope "example"))
    (should
     (equal
      (reference-explorer-monokakido--url "機会")
      (concat "mkdictionaries:///?text=%E6%A9%9F%E4%BC%9A"
              "&category=ja&scope=example")))))

(ert-deftest reference-explorer-monokakido-opens-url-without-shell ()
  (let ((context (reference-explorer-context-create :query "機会"))
        called)
    (cl-letf (((symbol-function
                'reference-explorer-monokakido-available-p)
               (lambda () t))
              ((symbol-function 'call-process)
               (lambda (&rest arguments)
                 (setq called arguments)
                 0)))
      (should (reference-explorer-monokakido-display context))
      (should
       (equal called
              '("open" nil 0 nil "-u"
                "mkdictionaries:///?text=%E6%A9%9F%E4%BC%9A"))))))

(provide 'reference-explorer-monokakido-test)
;;; reference-explorer-monokakido-test.el ends here
