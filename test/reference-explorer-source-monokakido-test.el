;;; reference-explorer-source-monokakido-test.el --- Monokakido source tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-source-monokakido)

(ert-deftest reference-explorer-source-monokakido-encodes-query ()
  (let ((reference-explorer-source-monokakido-category nil)
        (reference-explorer-source-monokakido-scope nil))
    (should
     (equal
      (reference-explorer-source-monokakido--url "説明 文&語")
      (concat "mkdictionaries:///?text="
              "%E8%AA%AC%E6%98%8E%20%E6%96%87%26%E8%AA%9E")))))

(ert-deftest reference-explorer-source-monokakido-includes-search-options ()
  (let ((reference-explorer-source-monokakido-category "ja")
        (reference-explorer-source-monokakido-scope "example"))
    (should
     (equal
      (reference-explorer-source-monokakido--url "機会")
      (concat "mkdictionaries:///?text=%E6%A9%9F%E4%BC%9A"
              "&category=ja&scope=example")))))

(ert-deftest reference-explorer-source-monokakido-delegates-without-shell ()
  (let (called outcome)
    (cl-letf (((symbol-function
                'reference-explorer-source-monokakido-available-p)
               (lambda (&optional _context) t))
              ((symbol-function 'call-process)
               (lambda (&rest arguments)
                 (setq called arguments)
                 0)))
      (reference-explorer-source-monokakido-search
       "機会" nil (lambda (value) (setq outcome value)))
      (should (eq (reference-explorer-search-outcome-status outcome)
                  'delegated))
      (should
       (equal called
              '("open" nil 0 nil "-u"
                "mkdictionaries:///?text=%E6%A9%9F%E4%BC%9A"))))))

(provide 'reference-explorer-source-monokakido-test)
;;; reference-explorer-source-monokakido-test.el ends here
