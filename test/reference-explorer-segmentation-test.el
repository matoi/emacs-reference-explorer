;;; reference-explorer-segmentation-test.el --- Phrase selection tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-segmentation)

(ert-deftest reference-explorer-segmentation-backends-are-pluggable ()
  (with-temp-buffer
    (insert "multi word phrase")
    (goto-char 8)
    (let ((reference-explorer-segmentation-backends
           (list (lambda (_position _start _end) '((1 . 18))))))
      (should (equal (reference-explorer-segmentation-word-at-point)
                     "multi word phrase")))))

(ert-deftest reference-explorer-segmentation-recognizes-emacs-word ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 3)
    (should (equal (reference-explorer-segmentation-word-at-point) "alpha"))))

(ert-deftest reference-explorer-segmentation-uses-visible-org-link-description ()
  (require 'org)
  (with-temp-buffer
    (org-mode)
    (insert "[[https://example.com][Example Link]]")
    (goto-char (point-min))
    (should (equal (reference-explorer-segmentation-word-at-point) "Example"))
    (search-forward "Link")
    (should (equal (reference-explorer-segmentation-word-at-point) "Link"))))

(ert-deftest reference-explorer-segmentation-maps-hidden-org-link-to-visible-position ()
  (require 'org)
  (with-temp-buffer
    (org-mode)
    (insert "[[https://example.com][Example Link]]")
    (goto-char (point-min))
    (should
     (= (reference-explorer-segmentation-visible-position-at-point)
        (progn (search-forward "Example Link") (match-beginning 0))))))

(ert-deftest reference-explorer-segmentation-segments-japanese-with-mecab ()
  (skip-unless (executable-find reference-explorer-segmentation-mecab-program))
  (with-temp-buffer
    (insert "日本語の文章")
    (goto-char 2)
    (should (equal (reference-explorer-segmentation-word-at-point) "日本語"))
    (goto-char 5)
    (should (equal (reference-explorer-segmentation-word-at-point) "文章"))))

(ert-deftest reference-explorer-segmentation-segments-visible-japanese-org-link ()
  (skip-unless (executable-find reference-explorer-segmentation-mecab-program))
  (require 'org)
  (with-temp-buffer
    (org-mode)
    (insert "[[https://example.com][日本語の文章]]")
    (goto-char (point-min))
    (should (equal (reference-explorer-segmentation-word-at-point) "日本語"))))

(ert-deftest reference-explorer-segmentation-prefers-longest-japanese-compound ()
  (skip-unless (executable-find reference-explorer-segmentation-mecab-program))
  (with-temp-buffer
    (insert "東京都庁")
    (goto-char 2)
    (should (equal (reference-explorer-segmentation-word-at-point) "東京都庁"))
    (should (member "東京"
                    (reference-explorer-segmentation-word-candidates-at-point)))))

(ert-deftest reference-explorer-segmentation-does-not-cross-japanese-particles ()
  (skip-unless (executable-find reference-explorer-segmentation-mecab-program))
  (with-temp-buffer
    (insert "日本語の文章")
    (goto-char 2)
    (should (equal (reference-explorer-segmentation-word-at-point) "日本語"))))

(provide 'reference-explorer-segmentation-test)
;;; reference-explorer-segmentation-test.el ends here
