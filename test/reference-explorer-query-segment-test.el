;;; reference-explorer-query-segment-test.el --- Phrase selection tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-query-segment)

(ert-deftest reference-explorer-query-segment-backends-are-pluggable ()
  (with-temp-buffer
    (insert "multi word phrase")
    (goto-char 8)
    (let ((reference-explorer-query-segment-backends
           (list (lambda (_position _start _end) '((1 . 18))))))
      (should (equal (reference-explorer-query-segment-word-at-point)
                     "multi word phrase")))))

(ert-deftest reference-explorer-query-segment-recognizes-emacs-word ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 3)
    (should (equal (reference-explorer-query-segment-word-at-point) "alpha"))))

(ert-deftest reference-explorer-query-segment-uses-visible-org-link-description ()
  (require 'org)
  (with-temp-buffer
    (org-mode)
    (insert "[[https://example.com][Example Link]]")
    (goto-char (point-min))
    (should (equal (reference-explorer-query-segment-word-at-point) "Example"))
    (search-forward "Link")
    (should (equal (reference-explorer-query-segment-word-at-point) "Link"))))

(ert-deftest reference-explorer-query-segment-maps-hidden-org-link-to-visible-position ()
  (require 'org)
  (with-temp-buffer
    (org-mode)
    (insert "[[https://example.com][Example Link]]")
    (goto-char (point-min))
    (should
     (= (reference-explorer-query-segment-visible-position-at-point)
        (progn (search-forward "Example Link") (match-beginning 0))))))

(ert-deftest reference-explorer-query-segment-segments-japanese-with-mecab ()
  (skip-unless (executable-find reference-explorer-query-segment-mecab-program))
  (with-temp-buffer
    (insert "日本語の文章")
    (goto-char 2)
    (should (equal (reference-explorer-query-segment-word-at-point) "日本語"))
    (goto-char 5)
    (should (equal (reference-explorer-query-segment-word-at-point) "文章"))))

(ert-deftest reference-explorer-query-segment-segments-visible-japanese-org-link ()
  (skip-unless (executable-find reference-explorer-query-segment-mecab-program))
  (require 'org)
  (with-temp-buffer
    (org-mode)
    (insert "[[https://example.com][日本語の文章]]")
    (goto-char (point-min))
    (should (equal (reference-explorer-query-segment-word-at-point) "日本語"))))

(ert-deftest reference-explorer-query-segment-prefers-shortest-two-character-mecab-phrase ()
  (with-temp-buffer
    (insert "公爵夫人")
    (goto-char 2)
    (let ((reference-explorer-query-segment-backends
           '(reference-explorer-query-segment-mecab-backend)))
      (cl-letf (((symbol-function
                  'reference-explorer-query-segment-mecab-backend)
                 (lambda (_position _start _end)
                   '((1 . 5) (1 . 4) (1 . 3) (1 . 2)))))
        (should (equal (reference-explorer-query-segment-word-at-point) "公爵"))
        (should (equal (reference-explorer-query-segment-word-candidates-at-point)
                       '("公爵夫人" "公爵夫" "公爵" "公")))))))

(ert-deftest reference-explorer-query-segment-mecab-initial-phrase-falls-back-to-one-character ()
  (with-temp-buffer
    (insert "公")
    (goto-char (point-min))
    (let ((reference-explorer-query-segment-backends
           '(reference-explorer-query-segment-mecab-backend)))
      (cl-letf (((symbol-function
                  'reference-explorer-query-segment-mecab-backend)
                 (lambda (_position _start _end) '((1 . 2)))))
        (should (equal (reference-explorer-query-segment-word-at-point) "公"))))))

(ert-deftest reference-explorer-query-segment-keeps-other-backend-preference ()
  (with-temp-buffer
    (insert "公爵夫人")
    (goto-char 2)
    (let ((reference-explorer-query-segment-backends
           (list (lambda (_position _start _end)
                   '((1 . 5) (1 . 3))))))
      (should (equal (reference-explorer-query-segment-word-at-point)
                     "公爵夫人")))))

(ert-deftest reference-explorer-query-segment-does-not-cross-japanese-particles ()
  (skip-unless (executable-find reference-explorer-query-segment-mecab-program))
  (with-temp-buffer
    (insert "日本語の文章")
    (goto-char 2)
    (should (equal (reference-explorer-query-segment-word-at-point) "日本語"))))

(provide 'reference-explorer-query-segment-test)
;;; reference-explorer-query-segment-test.el ends here
