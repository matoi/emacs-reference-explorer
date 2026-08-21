;;; reference-explorer-phrase-segmenter-emacs.el --- Emacs phrase segmenter -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Select symbol and word bounds using Emacs built-ins.

;;; Code:

(require 'reference-explorer-phrase-segmenter)
(require 'thingatpt)

(defun reference-explorer-phrase-segmenter-emacs (_context)
  "Return Emacs symbol and word candidates around point."
  (let ((candidates
         (sort
          (delete-dups
           (delq nil (list (bounds-of-thing-at-point 'symbol)
                           (bounds-of-thing-at-point 'word))))
          (lambda (left right)
            (> (- (cdr left) (car left))
               (- (cdr right) (car right)))))))
    (when candidates
      (reference-explorer-phrase-segmenter-result-create
       :candidates candidates
       :initial (car candidates)))))

(provide 'reference-explorer-phrase-segmenter-emacs)
;;; reference-explorer-phrase-segmenter-emacs.el ends here
