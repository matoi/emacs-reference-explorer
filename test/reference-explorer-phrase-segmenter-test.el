;;; reference-explorer-phrase-segmenter-test.el --- Phrase segmenter tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-phrase-segmenter)
(require 'reference-explorer-phrase-segmenter-emacs)
(require 'reference-explorer-phrase-segmenter-mecab)
(require 'reference-explorer-phrase-segmenter-org)

(ert-deftest reference-explorer-phrase-segmenters-are-pluggable ()
  (with-temp-buffer
    (insert "multi word phrase")
    (goto-char 8)
    (let ((reference-explorer-phrase-segmenters
           (list
            (lambda (_context)
              (reference-explorer-phrase-segmenter-result-create
               :candidates '((1 . 18)) :initial '(1 . 18))))))
      (should (equal (reference-explorer-phrase-segmenter-at-point)
                     "multi word phrase")))))

(ert-deftest reference-explorer-phrase-segmenter-honors-backend-initial-result ()
  (with-temp-buffer
    (insert "one two three")
    (goto-char 6)
    (let ((reference-explorer-phrase-segmenters
           (list
            (lambda (_context)
              (reference-explorer-phrase-segmenter-result-create
               :candidates '((1 . 14) (5 . 8) (5 . 14))
               :initial '(5 . 8))))))
      (should (equal (reference-explorer-phrase-segmenter-at-point) "two"))
      (should
       (equal (reference-explorer-phrase-segmenter-candidates-at-point)
              '("one two three" "two" "two three"))))))

(ert-deftest reference-explorer-phrase-segmenter-rejects-non-candidate-initial ()
  (with-temp-buffer
    (insert "word")
    (let ((reference-explorer-phrase-segmenters
           (list
            (lambda (_context)
              (reference-explorer-phrase-segmenter-result-create
               :candidates '((1 . 5)) :initial '(2 . 5))))))
      (should-error (reference-explorer-phrase-segmenter-at-point)))))

(ert-deftest reference-explorer-phrase-segmenter-rejects-out-of-buffer-bounds ()
  (with-temp-buffer
    (insert "word")
    (goto-char 2)
    (let ((reference-explorer-phrase-segmenters
           (list
            (lambda (_context)
              (reference-explorer-phrase-segmenter-result-create
               :candidates '((1 . 99)))))))
      (should-error (reference-explorer-phrase-segmenter-at-point)))))

(ert-deftest reference-explorer-phrase-segmenter-rejects-context-crossing-bounds ()
  (with-temp-buffer
    (insert "abcdefgh")
    (goto-char 4)
    (let ((reference-explorer-phrase-segmenter-context-functions
           (list
            (lambda (position)
              (reference-explorer-phrase-segmenter-context-create
               :position position :start 3 :end 7))))
          (reference-explorer-phrase-segmenters
           (list
            (lambda (_context)
              (reference-explorer-phrase-segmenter-result-create
               :candidates '((2 . 5)))))))
      (should-error (reference-explorer-phrase-segmenter-at-point)))))

(ert-deftest reference-explorer-phrase-segmenter-rejects-bounds-away-from-origin ()
  (with-temp-buffer
    (insert "one two")
    (goto-char 6)
    (let ((reference-explorer-phrase-segmenters
           (list
            (lambda (_context)
              (reference-explorer-phrase-segmenter-result-create
               :candidates '((1 . 4)))))))
      (should-error (reference-explorer-phrase-segmenter-at-point)))))

(ert-deftest reference-explorer-phrase-segmenter-normalizes-marker-bounds ()
  (with-temp-buffer
    (insert "word")
    (goto-char 2)
    (let* ((start (copy-marker 1))
           (end (copy-marker 5))
           (reference-explorer-phrase-segmenters
            (list
             (lambda (_context)
               (reference-explorer-phrase-segmenter-result-create
                :candidates (list (cons start end))
                :initial '(1 . 5)))))
           (result (reference-explorer-phrase-segmenter-result-at-point)))
      (should (equal
               (reference-explorer-phrase-segmenter-result-candidates result)
               '((1 . 5))))
      (should (equal
               (reference-explorer-phrase-segmenter-result-initial result)
               '(1 . 5)))
      (should (integerp
               (caar
                (reference-explorer-phrase-segmenter-result-candidates
                 result)))))))

(ert-deftest reference-explorer-phrase-segmenter-recognizes-emacs-word ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 3)
    (let ((reference-explorer-phrase-segmenters
           '(reference-explorer-phrase-segmenter-emacs)))
      (should
       (equal (reference-explorer-phrase-segmenter-at-point) "alpha")))))

(ert-deftest reference-explorer-phrase-segmenter-uses-visible-org-description ()
  (require 'org)
  (with-temp-buffer
    (org-mode)
    (insert "[[https://example.com][Example Link]]")
    (goto-char (point-min))
    (let ((reference-explorer-phrase-segmenters
           '(reference-explorer-phrase-segmenter-emacs)))
      (should (equal (reference-explorer-phrase-segmenter-at-point) "Example"))
      (search-forward "Link")
      (should (equal (reference-explorer-phrase-segmenter-at-point) "Link")))))

(ert-deftest reference-explorer-phrase-segmenter-maps-hidden-org-position ()
  (require 'org)
  (with-temp-buffer
    (org-mode)
    (insert "[[https://example.com][Example Link]]")
    (goto-char (point-min))
    (should
     (= (reference-explorer-phrase-segmenter-visible-position-at-point)
        (progn (search-forward "Example Link") (match-beginning 0))))))

(ert-deftest reference-explorer-phrase-segmenter-segments-japanese-with-mecab ()
  (skip-unless
   (executable-find reference-explorer-phrase-segmenter-mecab-program))
  (with-temp-buffer
    (insert "日本語の文章")
    (let ((reference-explorer-phrase-segmenters
           '(reference-explorer-phrase-segmenter-mecab)))
      (goto-char 2)
      (should (equal (reference-explorer-phrase-segmenter-at-point) "日本語"))
      (goto-char 5)
      (should (equal (reference-explorer-phrase-segmenter-at-point) "文章")))))

(ert-deftest reference-explorer-phrase-segmenter-segments-visible-japanese-org-link ()
  (skip-unless
   (executable-find reference-explorer-phrase-segmenter-mecab-program))
  (require 'org)
  (with-temp-buffer
    (org-mode)
    (insert "[[https://example.com][日本語の文章]]")
    (goto-char (point-min))
    (let ((reference-explorer-phrase-segmenters
           '(reference-explorer-phrase-segmenter-mecab)))
      (should (equal (reference-explorer-phrase-segmenter-at-point) "日本語")))))

(ert-deftest reference-explorer-phrase-segmenter-mecab-prefers-shortest-minimum ()
  (let ((reference-explorer-phrase-segmenter-mecab-initial-minimum-length 2))
    (should
     (equal
      (reference-explorer-phrase-segmenter-mecab--initial
       '((1 . 5) (1 . 4) (1 . 3) (1 . 2)))
      '(1 . 3)))))

(ert-deftest reference-explorer-phrase-segmenter-mecab-falls-back-to-one-character ()
  (let ((reference-explorer-phrase-segmenter-mecab-initial-minimum-length 2))
    (should
     (equal
      (reference-explorer-phrase-segmenter-mecab--initial '((1 . 2)))
      '(1 . 2)))))

(ert-deftest reference-explorer-phrase-segmenter-does-not-cross-particles ()
  (skip-unless
   (executable-find reference-explorer-phrase-segmenter-mecab-program))
  (with-temp-buffer
    (insert "日本語の文章")
    (goto-char 2)
    (let ((reference-explorer-phrase-segmenters
           '(reference-explorer-phrase-segmenter-mecab)))
      (should (equal (reference-explorer-phrase-segmenter-at-point) "日本語")))))

(provide 'reference-explorer-phrase-segmenter-test)
;;; reference-explorer-phrase-segmenter-test.el ends here
