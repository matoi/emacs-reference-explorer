;;; reference-explorer-ui-test.el --- Reference lookup tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-source-lookup)

(ert-deftest reference-explorer-ui-keeps-monokakido-explicit-by-default ()
  (let ((default-chain (cdr (assq t reference-explorer-provider-rules))))
    (should (memq 'monokakido (reference-explorer-provider-names)))
    (should-not (memq 'monokakido default-chain))
    (should (equal default-chain
                   (if (eq system-type 'darwin)
                       '(docset macos-dictionary lookup)
                     '(lookup))))))

(ert-deftest reference-explorer-ui-converts-standard-roman-readings ()
  (should (equal (reference-explorer-ui--roman-to-hiragana "kankyo")
                 "かんきょ"))
  (should (equal (reference-explorer-ui--roman-to-hiragana "nihon")
                 "にほん"))
  (should (equal (reference-explorer-ui--roman-to-hiragana "kanna")
                 "かんな")))

(ert-deftest reference-explorer-ui-conversion-keeps-last-complete-reading ()
  (should (equal (reference-explorer-ui--roman-to-hiragana "kanky")
                 "かん")))

(ert-deftest reference-explorer-ui-does-not-search-an-incomplete-first-syllable ()
  (should-not (reference-explorer-ui--backend-query "k" 'converted)))

(ert-deftest reference-explorer-ui-converted-query-normalizes-katakana ()
  (should (equal (reference-explorer-ui--backend-query "カンキョウ" 'converted)
                 "かんきょう")))

(ert-deftest reference-explorer-ui-converted-query-function-is-pluggable ()
  (let ((reference-explorer-ui-query-conversion-function
         (lambda (input) (concat "converted:" input))))
    (should (equal (reference-explorer-ui--backend-query "term" 'converted)
                   "converted:term"))))

(ert-deftest reference-explorer-ui-literal-query-is-unchanged ()
  (should (equal (reference-explorer-ui--backend-query "environment" 'literal)
                 "environment")))

(ert-deftest reference-explorer-ui-converted-completion-style-is-injected ()
  (let ((features (append '(migemo orderless) features))
        (reference-explorer-ui-converted-completion-style 'test-migemo-style)
        (completion-category-overrides nil))
    (should
     (equal (reference-explorer-ui--completion-overrides
             'converted 'reference-explorer-source-lookup-entry)
            '((reference-explorer-source-lookup-entry
               (styles test-migemo-style basic)))))))

(ert-deftest reference-explorer-ui-converted-completion-requires-a-style ()
  (let ((features (append '(migemo orderless) features))
        (reference-explorer-ui-converted-completion-style nil))
    (should-error (reference-explorer-ui--completion-overrides
                   'converted 'reference-explorer-source-lookup-entry)
                  :type 'user-error)))

(ert-deftest reference-explorer-ui-consult-mode-toggle-key ()
  (should (eq (lookup-key reference-explorer-ui-consult-map (kbd "M-m"))
              #'reference-explorer-ui-toggle-consult-mode))
  (should (eq (lookup-key reference-explorer-ui-consult-map (kbd "H-s"))
              #'reference-explorer-ui-consult-shorten-query))
  (should (eq (lookup-key reference-explorer-ui-consult-map (kbd "H-e"))
              #'reference-explorer-ui-consult-expand-query))
  (should (eq (lookup-key reference-explorer-ui-consult-map (kbd "H-."))
              #'reference-explorer-ui-consult-open-reference))
  (should (eq (lookup-key reference-explorer-ui-consult-map (kbd "H-v"))
              #'reference-explorer-ui-preview-scroll-up))
  (should (eq (lookup-key reference-explorer-ui-consult-map (kbd "H-V"))
              #'reference-explorer-ui-preview-scroll-down))
  (should (eq (lookup-key reference-explorer-ui-consult-map (kbd "H-i"))
              #'reference-explorer-ui-consult-activate-preview))
  (should-not (lookup-key reference-explorer-ui-consult-map (kbd "H-M-.")))
  (should (eq (lookup-key reference-explorer-ui-consult-map (kbd "TAB"))
              #'reference-explorer-ui-select-candidate)))

(ert-deftest reference-explorer-ui-consult-query-can-shrink-and-expand ()
  (let ((reference-explorer-ui--consult-query-options
         '("公爵夫人" "公爵" "公"))
        (reference-explorer-ui--consult-query-index 0)
        (input "公爵夫人"))
    (cl-letf (((symbol-function 'minibuffer-contents-no-properties)
               (lambda () input))
              ((symbol-function 'delete-minibuffer-contents)
               (lambda () (setq input "")))
              ((symbol-function 'insert)
               (lambda (text) (setq input (concat input text)))))
      (reference-explorer-ui-consult-shorten-query)
      (should (equal input "公爵"))
      (reference-explorer-ui-consult-shorten-query)
      (should (equal input "公"))
      (reference-explorer-ui-consult-expand-query)
      (should (equal input "公爵")))))

(ert-deftest reference-explorer-ui-quick-selector-keymap-is-non-invasive ()
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "H-n"))
              #'reference-explorer-ui-quick-next))
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "H-p"))
              #'reference-explorer-ui-quick-previous))
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "H-s"))
              #'reference-explorer-ui-quick-shorten-query))
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "H-e"))
              #'reference-explorer-ui-quick-expand-query))
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "H-q"))
              #'reference-explorer-ui-quick-quit))
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "H-v"))
              #'reference-explorer-ui-preview-scroll-up))
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "H-V"))
              #'reference-explorer-ui-preview-scroll-down))
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "H-i"))
              #'reference-explorer-ui-quick-activate-preview))
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "TAB"))
              #'reference-explorer-ui-quick-display-entry))
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "H-."))
              #'reference-explorer-ui-quick-open-reference))
  (should-not (lookup-key reference-explorer-ui-quick-map (kbd "H-M-.")))
  (should (eq (lookup-key reference-explorer-ui-quick-map (kbd "M-m"))
              #'reference-explorer-ui-quick-open-consult))
  ;; Unrecognized keys must fall through the transient map to the source
  ;; buffer instead of being captured by quick Lookup.
  (should-not (lookup-key reference-explorer-ui-quick-map (kbd "a"))))

(ert-deftest reference-explorer-ui-quick-selector-passes-through-other-keys ()
  (with-temp-buffer
    (let ((map (make-sparse-keymap))
          exited)
      (define-key map (kbd "H-n") #'ignore)
      (set-transient-map map t (lambda () (setq exited t)))
      (execute-kbd-macro (kbd "a"))
      (should (equal (buffer-string) "a"))
      (should exited))))

(ert-deftest reference-explorer-ui-quick-reference-uses-provider-order ()
  (let ((reference-explorer-ui--quick-session
         (reference-explorer-ui--make-quick-session
          :query "query"
          :source-marker (copy-marker 1)
          :source-window (selected-window)))
        dispatched)
    (cl-letf (((symbol-function 'reference-explorer-run-context)
               (lambda (context) (setq dispatched context))))
      (reference-explorer-ui-quick-open-reference)
      (should (equal (reference-explorer-context-query dispatched) "query")))))

(ert-deftest reference-explorer-ui-consult-reference-uses-provider-order ()
  (let ((reference-explorer-ui--consult-origin
         (reference-explorer-context-create
          :query nil
          :marker (copy-marker 1)
          :window (selected-window)))
        dispatched)
    (cl-letf (((symbol-function 'minibuffer-contents-no-properties)
               (lambda () "edited query"))
              ((symbol-function 'reference-explorer-run-context)
               (lambda (context) (setq dispatched context))))
      (reference-explorer-ui-consult-open-reference)
      (should
       (equal (reference-explorer-context-query dispatched)
              "edited query")))))

(ert-deftest reference-explorer-ui-quick-selector-cycles-candidates ()
  (let* ((session
          (reference-explorer-ui--make-quick-session
           :entries '(first second third)
           :index 0))
         (reference-explorer-ui--quick-session session))
    (cl-letf (((symbol-function 'reference-explorer-ui--quick-refresh)
               #'ignore))
      (reference-explorer-ui-quick-next)
      (should (eq (reference-explorer-ui--quick-current-entry) 'second))
      (reference-explorer-ui-quick-previous)
      (should (eq (reference-explorer-ui--quick-current-entry) 'first))
      (reference-explorer-ui-quick-previous)
      (should (eq (reference-explorer-ui--quick-current-entry) 'third)))))

(ert-deftest reference-explorer-ui-quick-list-renders-initial-selection ()
  (let* ((buffer (generate-new-buffer " *environment-quick-list-test*"))
         (session
          (reference-explorer-ui--make-quick-session
           :entries '(first second)
           :index 0
           :list-buffer buffer)))
    (unwind-protect
        (cl-letf (((symbol-function 'lookup-entry-heading) #'symbol-name)
                  ((symbol-function 'reference-explorer-source-lookup-entry-source)
                   (lambda (_entry) "dictionary")))
          (reference-explorer-ui--quick-render-list session)
          (with-current-buffer buffer
            (should (equal (buffer-string)
                           (concat "first  dictionary\n"
                                   "second  dictionary\n")))
            (should
             (reference-explorer-ui--face-includes-p
              'reference-explorer-ui-quick-current
               (get-text-property
               (point-min)
               'face)))
            (should (= (line-number-at-pos (point)) 1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest reference-explorer-ui-quick-list-renders-empty-result-state ()
  (let* ((buffer (generate-new-buffer " *environment-quick-empty-test*"))
         (session
          (reference-explorer-ui--make-quick-session
           :entries nil
           :index 0
           :list-buffer buffer)))
    (unwind-protect
        (progn
          (reference-explorer-ui--quick-render-list session)
          (with-current-buffer buffer
            (should (equal (buffer-string) "一致なし"))
            (should (reference-explorer-ui--face-includes-p
                     'shadow (get-text-property (point-min) 'face)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest reference-explorer-ui-quick-highlights-source-query ()
  (with-temp-buffer
    (insert "alpha beta")
    (let ((session
           (reference-explorer-ui--make-quick-session
            :query "alpha"
            :source-marker (copy-marker 3))))
      (let ((reference-explorer-ui-word-bound-candidates-function
             (lambda () '((1 . 6)))))
        (reference-explorer-ui--quick-highlight-source session))
      (let ((overlay
             (reference-explorer-ui--quick-session-source-overlay session)))
        (should (overlayp overlay))
        (should (equal (buffer-substring-no-properties
                        (overlay-start overlay) (overlay-end overlay))
                       "alpha"))
        (should (eq (overlay-get overlay 'face)
                    'reference-explorer-ui-source-highlight))))))

(ert-deftest reference-explorer-ui-quick-list-scrolls-only-at-visible-edge ()
  (let ((reference-explorer-ui-quick-max-candidates 3)
        (session
         (reference-explorer-ui--make-quick-session
          :entries '(zero one two three four five)
          :index 0)))
    (should (equal (reference-explorer-ui--quick-visible-entries session)
                   '(zero one two)))
    (should (= (reference-explorer-ui--quick-session-list-offset session) 0))
    (setf (reference-explorer-ui--quick-session-index session) 2)
    (should (equal (reference-explorer-ui--quick-visible-entries session)
                   '(zero one two)))
    (should (= (reference-explorer-ui--quick-session-list-offset session) 0))
    (setf (reference-explorer-ui--quick-session-index session) 3)
    (should (equal (reference-explorer-ui--quick-visible-entries session)
                   '(one two three)))
    (should (= (reference-explorer-ui--quick-session-list-offset session) 1))
    (setf (reference-explorer-ui--quick-session-index session) 5)
    (should (equal (reference-explorer-ui--quick-visible-entries session)
                   '(three four five)))
    (should (= (reference-explorer-ui--quick-session-list-offset session) 3))))

(ert-deftest reference-explorer-ui-quick-frame-deletion-deactivates-session ()
  (let* ((session
          (reference-explorer-ui--make-quick-session
           :list-frame 'candidate-frame))
         (reference-explorer-ui--quick-session session)
         scheduled
         exited)
    (setf (reference-explorer-ui--quick-session-exit-function session)
          (lambda () (setq exited t)))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest arguments)
                 (setq scheduled (cons function arguments)))))
      (reference-explorer-ui--quick-list-frame-deleted 'candidate-frame))
    (should-not (reference-explorer-ui--quick-session-list-frame session))
    (should scheduled)
    (apply (car scheduled) (cdr scheduled))
    (should exited)))

(ert-deftest reference-explorer-ui-quick-cleanup-releases-owned-resources ()
  (let* ((buffer (generate-new-buffer " *environment-quick-cleanup*"))
         (preview (reference-explorer-ui--make-preview
                   'preview-frame 'preview-buffer))
         (source-overlay (make-overlay (point-min) (point-min)))
         (session
          (reference-explorer-ui--make-quick-session
           :list-frame 'candidate-frame
           :list-buffer buffer
           :preview preview
           :source-overlay source-overlay))
         (reference-explorer-ui--quick-session session)
         deleted
         closed)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_frame) t))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _force) (push frame deleted)))
              ((symbol-function
                'reference-explorer-ui--close-temporary-preview)
               (lambda (owned-preview) (setq closed owned-preview))))
      (reference-explorer-ui--quick-cleanup))
    (should-not reference-explorer-ui--quick-session)
    (should (equal deleted '(candidate-frame)))
    (should (eq closed preview))
    (should-not (overlay-buffer source-overlay))
    (should-not (buffer-live-p buffer))))

(ert-deftest reference-explorer-ui-quick-no-match-opens-selector ()
  (let (session)
    (cl-letf (((symbol-function 'lookup-initialize) #'ignore)
              ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function
                'reference-explorer-ui--quick-query-candidates-at-point)
               (lambda () '("missing-symbol")))
              ((symbol-function
                'reference-explorer-source-lookup--quick-search-entries)
               (lambda (_query) nil))
              ((symbol-function
                'reference-explorer-ui--quick-show-list-frame)
               (lambda (owned-session)
                 (setq session owned-session)
                 t))
              ((symbol-function 'set-transient-map)
               (lambda (&rest _arguments) #'reference-explorer-ui--quick-cleanup))
              ((symbol-function 'reference-explorer-ui--quick-highlight-source)
               #'ignore)
              ((symbol-function 'reference-explorer-ui--quick-schedule-preview)
               #'ignore)
              ((symbol-function 'reference-explorer-ui--quick-show-help)
               #'ignore))
      (reference-explorer-source-lookup-quick-lookup-at-point))
    (unwind-protect
        (progn
          (should (eq session reference-explorer-ui--quick-session))
          (should (equal (reference-explorer-ui--quick-session-query session)
                         "missing-symbol"))
          (should-not (reference-explorer-ui--quick-session-entries session)))
      (reference-explorer-ui--quick-cleanup))))

(ert-deftest reference-explorer-ui-quick-empty-context-reports-without-search ()
  (let (reported searched)
    (cl-letf (((symbol-function 'lookup-initialize) #'ignore)
              ((symbol-function
                'reference-explorer-ui--quick-query-candidates-at-point)
               (lambda () nil))
              ((symbol-function
                'reference-explorer-source-lookup--quick-search-entries)
               (lambda (_query) (setq searched t)))
              ((symbol-function 'message)
               (lambda (format-string &rest arguments)
                 (setq reported (apply #'format format-string arguments)))))
      (reference-explorer-source-lookup-quick-lookup-at-point))
    (should-not searched)
    (should (string-match-p "no searchable text" reported))))

(ert-deftest reference-explorer-ui-quick-terminal-uses-consult-fallback ()
  (let (called)
    (cl-letf (((symbol-function 'lookup-initialize) #'ignore)
              ((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
              ((symbol-function
                'reference-explorer-ui--quick-query-candidates-at-point)
               (lambda () '("query")))
              ((symbol-function
                'reference-explorer-source-lookup--quick-search-entries)
               (lambda (_query) nil))
              ((symbol-function 'reference-explorer-source-lookup--consult-loop)
               (lambda (query mode &optional queries)
                 (setq called (list query mode queries)))))
      (reference-explorer-source-lookup-quick-lookup-at-point))
    (should (equal called '("query" literal ("query"))))
    (should-not reference-explorer-ui--quick-session)))

(ert-deftest reference-explorer-ui-quick-display-failure-cleans-session ()
  (let (reported)
    (cl-letf (((symbol-function 'lookup-initialize) #'ignore)
              ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function
                'reference-explorer-ui--quick-query-candidates-at-point)
               (lambda () '("query")))
              ((symbol-function
                'reference-explorer-source-lookup--quick-search-entries)
               (lambda (_query) '(entry)))
              ((symbol-function
                'reference-explorer-ui--quick-show-list-frame)
               (lambda (_session) nil))
              ((symbol-function 'message)
               (lambda (format-string &rest arguments)
                 (setq reported (apply #'format format-string arguments)))))
      (reference-explorer-source-lookup-quick-lookup-at-point))
    (should-not reference-explorer-ui--quick-session)
    (should (string-match-p "cannot display candidates" reported))))

(ert-deftest reference-explorer-ui-quick-consult-transfer-preserves-query ()
  (let* ((session
         (reference-explorer-ui--make-quick-session
           :query "query"
           :query-options '(("long") ("query") ("short"))
           :consult-function
           (lambda (_entries)
             (reference-explorer-source-lookup--consult-loop
              "query" 'literal '("long" "query" "short")))))
         (reference-explorer-ui--quick-session session)
         transferred)
    (setf (reference-explorer-ui--quick-session-exit-function session)
          #'reference-explorer-ui--quick-cleanup)
    (cl-letf (((symbol-function 'reference-explorer-source-lookup--consult-loop)
               (lambda (query mode &optional queries)
                 (setq transferred (list query mode queries)))))
      (reference-explorer-ui-quick-open-consult))
    (should-not reference-explorer-ui--quick-session)
    (should (equal transferred
                   '("query" literal ("long" "query" "short"))))))

(ert-deftest reference-explorer-ui-quick-display-commits-current-entry ()
  (let* ((session
          (reference-explorer-ui--make-quick-session
           :entries '(first second)
           :index 1))
         (reference-explorer-ui--quick-session session)
         cancelled
         displayed)
    (cl-letf (((symbol-function 'reference-explorer-ui--quick-cancel-preview)
               (lambda (owned-session) (setq cancelled owned-session)))
              ((symbol-function 'reference-explorer-ui--display-entry)
               (lambda (entry) (setq displayed entry))))
      (reference-explorer-ui-quick-display-entry))
    (should (eq cancelled session))
    (should (eq displayed 'second))))

(ert-deftest reference-explorer-ui-quick-display-targets-source-window ()
  (save-window-excursion
    (delete-other-windows)
    (let* ((original-window (selected-window))
           (source-window (split-window-right))
           (session
            (reference-explorer-ui--make-quick-session
             :entries '(entry)
             :index 0
             :source-window source-window))
           (reference-explorer-ui--quick-session session)
           displayed-in)
      (cl-letf (((symbol-function
                  'reference-explorer-ui--quick-cancel-preview)
                 #'ignore)
                ((symbol-function 'reference-explorer-ui--display-entry)
                 (lambda (_entry) (setq displayed-in (selected-window)))))
        (reference-explorer-ui-quick-display-entry))
      (should (eq displayed-in source-window))
      (should (eq (selected-window) original-window)))))

(ert-deftest reference-explorer-ui-quick-promotes-preview-before-cleanup ()
  (let* (exited
         activated
         (preview
          (reference-explorer-ui--make-preview 'frame 'buffer 'entry))
         (session
          (reference-explorer-ui--make-quick-session
           :preview preview
           :entries '(entry)
           :index 0
           :source-window 'source-window
           :exit-function (lambda () (setq exited t))))
         (reference-explorer-ui--quick-session session)
         (reference-explorer-ui--active-temporary-preview preview))
    (cl-letf (((symbol-function
                'reference-explorer-ui--activate-preview-interaction)
               (lambda (candidate origin-window)
                 (setq activated (cons candidate origin-window))))
              ((symbol-function
                'reference-explorer-ui--active-webkit-preview-xwidget)
               (lambda () 'preview-xwidget)))
      (reference-explorer-ui-quick-activate-preview))
    (should exited)
    (should-not (reference-explorer-ui--quick-session-preview session))
    (should (equal activated (cons preview 'source-window)))))

(ert-deftest reference-explorer-ui-promotes-shr-preview-to-selected-content ()
  (let ((preview
         (reference-explorer-ui--make-preview nil nil 'lookup-entry))
        displayed)
    (cl-letf (((symbol-function
                'reference-explorer-ui--display-entry-for-interaction)
               (lambda (entry origin-window)
                 (setq displayed (cons entry origin-window)))))
      (reference-explorer-ui--activate-preview-interaction
       preview 'source-window))
    (should (equal displayed '(lookup-entry . source-window)))))

(ert-deftest reference-explorer-ui-quick-list-position-stays-inside-frame ()
  (let ((session
         (reference-explorer-ui--make-quick-session
          :list-frame 'candidate
          :source-window 'source))
        positioned)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_frame) t))
              ((symbol-function 'window-frame) (lambda (_window) 'parent))
              ((symbol-function 'frame-pixel-width)
               (lambda (frame) (if (eq frame 'parent) 1000 300)))
              ((symbol-function 'frame-pixel-height)
               (lambda (frame) (if (eq frame 'parent) 800 200)))
              ((symbol-function 'window-default-line-height)
               (lambda (_window) 20))
              ((symbol-function
                'reference-explorer-ui--quick-point-position)
               (lambda (_window) '(900 700)))
              ((symbol-function 'set-frame-position)
               (lambda (_frame left top) (setq positioned (list left top)))))
      (reference-explorer-ui--quick-position-list-frame session))
    (should (equal positioned '(696 496)))))

(ert-deftest reference-explorer-ui-registers-embark-actions-and-exporter ()
  (unless (require 'embark nil t)
    (ert-skip "Embark is unavailable"))
  (should (eq (lookup-key reference-explorer-source-lookup-embark-map (kbd "RET"))
              #'reference-explorer-source-lookup-display-candidate))
  (should (eq (lookup-key reference-explorer-source-lookup-embark-map (kbd "w"))
              #'reference-explorer-source-lookup-copy-candidate))
  (should (eq (alist-get 'reference-explorer-source-lookup-entry embark-exporters-alist)
              #'reference-explorer-source-lookup-export-candidates))
  (should
   (eq (alist-get 'reference-explorer-source-docset-result
                  embark-default-action-overrides)
       #'reference-explorer-ui-display-docset-candidate))
  (should
   (eq (lookup-key reference-explorer-ui-docset-embark-map (kbd "b"))
       #'reference-explorer-ui-browse-docset-candidate)))

(ert-deftest reference-explorer-ui-docset-provider-opens-quick-selector ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "sample")
    (goto-char (point-min))
    (let* ((docset (reference-explorer-source-docset-create :name "Emacs_Lisp"))
           (result (reference-explorer-source-docset-result-create
                    :name "sample" :type "Function" :path "sample.html"
                    :docset docset :exact t))
           (context (reference-explorer-context-create
                     :query "sample" :marker (copy-marker (point))
                     :window (selected-window) :automatic t))
           opened)
      (cl-letf (((symbol-function 'reference-explorer-source-docset-for-mode)
                 (lambda (_mode) (list docset)))
                ((symbol-function 'reference-explorer-source-docset-search)
                 (lambda (_query _mode) (list result)))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'reference-explorer-ui--quick-open-session)
                 (lambda (session) (setq opened session))))
        (reference-explorer-ui-docset-provider-display context))
      (should (equal (reference-explorer-ui--quick-session-query opened)
                     "sample"))
      (should (equal (reference-explorer-ui--quick-session-entries opened)
                     (list result))))))

(ert-deftest reference-explorer-ui-docset-provider-falls-through-when-absent ()
  (with-temp-buffer
    (let ((context (reference-explorer-context-create
                    :query "sample" :marker (copy-marker (point))
                    :window (selected-window) :automatic t)))
      (cl-letf (((symbol-function 'reference-explorer-source-docset-for-mode)
                 (lambda (_mode) nil)))
        (should-error
         (reference-explorer-ui-docset-provider-display context)
         :type 'reference-explorer-provider-unavailable)))))

(ert-deftest reference-explorer-ui-explicit-quick-forwarding-bypasses-order ()
  (let ((reference-explorer-ui--quick-session
         (reference-explorer-ui--make-quick-session
          :query "query"
          :source-marker (copy-marker 1)
          :source-window (selected-window)))
        calls)
    (cl-letf (((symbol-function 'reference-explorer-run-provider)
               (lambda (provider context)
                 (push (list provider
                             (reference-explorer-context-query context))
                       calls))))
      (reference-explorer-ui-quick-macos-dictionary)
      (reference-explorer-ui-quick-monokakido)
      (should
       (equal (nreverse calls)
              '((macos-dictionary "query") (monokakido "query")))))))

(ert-deftest reference-explorer-ui-explicit-consult-forwarding-bypasses-order ()
  (let ((reference-explorer-ui--consult-origin
         (reference-explorer-context-create
          :query nil
          :marker (copy-marker 1)
          :window (selected-window)))
        calls)
    (cl-letf (((symbol-function 'minibuffer-contents-no-properties)
               (lambda () "edited query"))
              ((symbol-function 'reference-explorer-run-provider)
               (lambda (provider context)
                 (push (list provider
                             (reference-explorer-context-query context))
                       calls))))
      (reference-explorer-ui-consult-macos-dictionary)
      (reference-explorer-ui-consult-monokakido)
      (should
       (equal (nreverse calls)
              '((macos-dictionary "edited query")
                (monokakido "edited query")))))))

(ert-deftest reference-explorer-ui-preview-is-temporary-until-commit ()
  (let (shown deleted)
    (cl-letf (((symbol-function
                'reference-explorer-ui--show-temporary-preview)
               (lambda (entry)
                 (setq shown entry)
                 'temporary-frame))
              ((symbol-function
                'reference-explorer-ui--close-temporary-preview)
               (lambda (popup)
                 (push popup deleted))))
      (let ((state (reference-explorer-ui--preview-state)))
        (funcall state 'preview 'entry)
        (should (eq shown 'entry))
        (funcall state 'exit nil)
        (should (equal deleted '(temporary-frame)))))))

(ert-deftest reference-explorer-ui-consult-retains-promoted-preview ()
  (let ((preview (reference-explorer-ui--make-preview 'frame 'buffer))
        (reference-explorer-ui--preview-interaction-request nil)
        closed)
    (cl-letf (((symbol-function
                'reference-explorer-ui--show-temporary-preview)
               (lambda (_entry) preview))
              ((symbol-function
                'reference-explorer-ui--close-temporary-preview)
               (lambda (_preview) (setq closed t))))
      (let ((state (reference-explorer-ui--preview-state)))
        (funcall state 'preview 'entry)
        (setq reference-explorer-ui--preview-interaction-request preview)
        (funcall state 'exit nil)
        (should-not closed)
        (should-not reference-explorer-ui--preview-interaction-request)))))

(ert-deftest reference-explorer-ui-consult-promotes-shr-preview ()
  (let* ((preview
          (reference-explorer-ui--make-preview nil nil 'lookup-entry))
         (reference-explorer-ui--active-temporary-preview preview)
         (reference-explorer-ui--preview-interaction-request nil)
         (reference-explorer-ui--consult-origin
          (reference-explorer-context-create :window 'source-window))
         (tag (make-symbol "reference-explorer-ui-test-control"))
         (reference-explorer-ui--consult-toggle-tag tag))
    (cl-letf (((symbol-function
                'reference-explorer-ui--active-webkit-preview-xwidget)
               (lambda () nil)))
      (should
       (equal (catch tag
                (reference-explorer-ui-consult-activate-preview))
              (list 'interact preview 'source-window))))
    (should-not reference-explorer-ui--preview-interaction-request)))

(ert-deftest reference-explorer-ui-consult-docset-promotes-preview ()
  (let ((preview (reference-explorer-ui--make-preview 'frame 'buffer))
        activated)
    (cl-letf (((symbol-function 'reference-explorer-ui--consult-docset-read)
               (lambda (_query _mode)
                 (list 'interact preview 'origin-window)))
              ((symbol-function
                'reference-explorer-ui--activate-preview-interaction)
               (lambda (candidate origin-window)
                 (setq activated (cons candidate origin-window)))))
      (reference-explorer-ui-consult-docset
       "require" 'ruby-ts-mode 'origin-window))
    (should (equal activated (cons preview 'origin-window)))))

(ert-deftest reference-explorer-ui-thesaurus-consult-promotes-preview ()
  (let* ((preview
          (reference-explorer-ui--make-preview nil nil 'lookup-entry))
         (reference-explorer-ui--active-temporary-preview preview)
         activated)
    (cl-letf (((symbol-function
                'reference-explorer-ui--thesaurus-consult-candidate)
               (lambda (_target _id) "candidate"))
              ((symbol-function 'require)
               (lambda (&rest _arguments) t))
              ((symbol-function 'consult--read)
               (lambda (&rest _arguments)
                 (reference-explorer-ui-consult-activate-preview)))
              ((symbol-function
                'reference-explorer-ui--active-webkit-preview-xwidget)
               (lambda () nil))
              ((symbol-function
                'reference-explorer-ui--activate-preview-interaction)
               (lambda (candidate origin-window)
                 (setq activated (cons candidate origin-window)))))
      (reference-explorer-ui--consult-thesaurus '(target) 'source-window))
    (should (equal activated (cons preview 'source-window)))))

(ert-deftest reference-explorer-ui-scrolls-the-active-preview ()
  (save-window-excursion
    (with-temp-buffer
      (dotimes (number 100)
        (insert (format "Preview line %d\n" number)))
      (switch-to-buffer (current-buffer))
      (goto-char (point-min))
      (let ((reference-explorer-ui--active-temporary-preview
             (reference-explorer-ui--make-preview
              (selected-frame) (current-buffer))))
        (set-window-start (selected-window) (point-min))
        (reference-explorer-ui-preview-scroll-up)
        (should (> (window-start) (point-min)))
        (reference-explorer-ui-preview-scroll-down)
        (should (= (window-start) (point-min)))))))

(ert-deftest reference-explorer-ui-copies-webkit-preview-selection ()
  (let* ((buffer (generate-new-buffer " *environment-webkit-copy*"))
         (preview
          (reference-explorer-ui--make-preview 'preview-frame buffer))
         (reference-explorer-ui--active-temporary-preview preview)
         copied-script
         copied-text)
    (unwind-protect
        (with-current-buffer buffer
          (setq-local major-mode 'xwidget-webkit-mode)
          (cl-letf (((symbol-function
                      'reference-explorer-ui--preview-live-p)
                     (lambda (_preview) t))
                    ((symbol-function 'get-buffer-xwidgets)
                     (lambda (_buffer) '(preview-xwidget)))
                    ((symbol-function 'xwidget-webkit-execute-script)
                     (lambda (_xwidget script callback)
                       (setq copied-script script)
                       (funcall callback "selected documentation")))
                    ((symbol-function 'kill-new)
                     (lambda (text &optional _replace)
                       (setq copied-text text))))
            (reference-explorer-ui-preview-copy-selection)
            (should (equal copied-script
                           "window.getSelection().toString();"))
            (should (equal copied-text "selected documentation"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest reference-explorer-ui-closes-only-the-owned-preview-buffer ()
  (let ((owned (generate-new-buffer " *environment-preview-owned*"))
        (other (generate-new-buffer " *environment-preview-other*"))
        preview
        deleted)
    (unwind-protect
        (progn
          (setq preview
                (reference-explorer-ui--make-preview
                 'preview-frame owned))
          (cl-letf (((symbol-function 'frame-live-p)
                     (lambda (_frame) t))
                    ((symbol-function 'delete-frame)
                     (lambda (frame &optional _force)
                       (setq deleted frame))))
            (reference-explorer-ui--close-temporary-preview preview))
          (should (eq deleted 'preview-frame))
          (should-not (buffer-live-p owned))
          (should (buffer-live-p other)))
      (when (buffer-live-p owned)
        (kill-buffer owned))
      (when (buffer-live-p other)
        (kill-buffer other)))))

(ert-deftest reference-explorer-ui-closes-frame-before-xwidget-view ()
  (let ((buffer (generate-new-buffer " *environment-webkit-owned*"))
        (preview nil)
        events)
    (unwind-protect
        (progn
          (setq preview
                (reference-explorer-ui--make-preview 'preview-frame buffer))
          (cl-letf (((symbol-function 'frame-live-p) (lambda (_frame) t))
                    ((symbol-function
                      'reference-explorer-ui--delete-xwidget-views)
                     (lambda (owned-buffer)
                       (push (list 'view owned-buffer) events)))
                    ((symbol-function 'delete-frame)
                     (lambda (frame &optional _force)
                       (push (list 'frame frame) events))))
            (reference-explorer-ui--close-temporary-preview preview))
          (should (equal (nreverse events)
                         `((frame preview-frame) (view ,buffer)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest reference-explorer-ui-closes-buffer-after-frame-is-gone ()
  (let* ((buffer (generate-new-buffer " *environment-preview-orphan*"))
         (preview
          (reference-explorer-ui--make-preview 'deleted-frame buffer)))
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_frame) nil)))
      (reference-explorer-ui--close-temporary-preview preview))
    (should-not (buffer-live-p buffer))))

(ert-deftest reference-explorer-ui-cleans-up-buffer-on-frame-deletion ()
  (let ((buffer (generate-new-buffer " *environment-preview-deleted*"))
        scheduled)
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (_frame parameter)
                 (and (eq parameter
                          'reference-explorer-ui-preview-buffer)
                      buffer)))
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest args)
                 (setq scheduled (cons function args))
                 'cleanup-timer))
              ((symbol-function 'reference-explorer-ui--delete-xwidget-views)
               #'ignore))
      (reference-explorer-ui--preview-frame-deleted 'preview-frame))
    (should (buffer-live-p buffer))
    (should scheduled)
    (apply (car scheduled) (cdr scheduled))
    (should-not (buffer-live-p buffer))))

(ert-deftest reference-explorer-ui-hides-reusable-webkit-preview ()
  (let* ((buffer (generate-new-buffer " *environment-preview-webkit*"))
         (preview
          (reference-explorer-ui--make-preview 'preview-frame buffer))
         (reference-explorer-ui--docset-webkit-preview-caches
          (make-hash-table :test #'eq))
         hidden)
    (unwind-protect
        (cl-letf (((symbol-function 'frame-live-p) (lambda (_frame) t))
                  ((symbol-function 'frame-parent)
                   (lambda (_frame) 'parent-frame))
                  ((symbol-function 'make-frame-invisible)
                   (lambda (frame &optional _force)
                     (setq hidden frame))))
          (reference-explorer-ui--cache-docset-webkit-preview
           'parent-frame preview)
          (reference-explorer-ui--close-temporary-preview preview)
          (should (eq hidden 'preview-frame))
          (should (buffer-live-p buffer))
          (should (eq
                   (reference-explorer-ui--docset-webkit-cache 'parent-frame)
                   preview)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest reference-explorer-ui-keeps-separate-webkit-cache-per-frame ()
  (let ((reference-explorer-ui--docset-webkit-preview-caches
         (make-hash-table :test #'eq))
        (first (reference-explorer-ui--make-preview 'child-a 'buffer-a))
        (second (reference-explorer-ui--make-preview 'child-b 'buffer-b)))
    (reference-explorer-ui--cache-docset-webkit-preview 'parent-a first)
    (reference-explorer-ui--cache-docset-webkit-preview 'parent-b second)
    (should (eq (reference-explorer-ui--docset-webkit-cache 'parent-a)
                first))
    (should (eq (reference-explorer-ui--docset-webkit-cache 'parent-b)
                second))
    (should (= (hash-table-count
                reference-explorer-ui--docset-webkit-preview-caches)
               2))))

(ert-deftest reference-explorer-ui-uncaches-only-deleted-webkit-frame ()
  (let ((reference-explorer-ui--docset-webkit-preview-caches
         (make-hash-table :test #'eq))
        (first (reference-explorer-ui--make-preview 'child-a 'buffer-a))
        (second (reference-explorer-ui--make-preview 'child-b 'buffer-b)))
    (reference-explorer-ui--cache-docset-webkit-preview 'parent-a first)
    (reference-explorer-ui--cache-docset-webkit-preview 'parent-b second)
    (should (eq
             (reference-explorer-ui--uncache-docset-webkit-preview-frame
              'child-a)
             first))
    (should-not (reference-explorer-ui--docset-webkit-cache 'parent-a))
    (should (eq (reference-explorer-ui--docset-webkit-cache 'parent-b)
                second))))

(ert-deftest reference-explorer-ui-webkit-load-cleans-only-obsolete-html ()
  (let ((current (make-temp-file "reference-explorer-source-docset-current-"))
        (obsolete (make-temp-file "reference-explorer-source-docset-obsolete-"))
        (buffer (generate-new-buffer " *environment-preview-webkit*")))
    (unwind-protect
        (with-current-buffer buffer
          (setq reference-explorer-ui--docset-preview-file current
                reference-explorer-ui--docset-preview-obsolete-files
                (list obsolete))
          (reference-explorer-ui--delete-obsolete-docset-preview-files)
          (should (file-exists-p current))
          (should-not (file-exists-p obsolete))
          (should-not reference-explorer-ui--docset-preview-obsolete-files))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (file-exists-p current)
        (delete-file current))
      (when (file-exists-p obsolete)
        (delete-file obsolete)))))

(ert-deftest reference-explorer-ui-webkit-callback-cleans-after-load-changed ()
  (let ((obsolete (make-temp-file "reference-explorer-source-docset-obsolete-"))
        (buffer (generate-new-buffer " *environment-preview-webkit*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local xwidget-webkit--loading-p t
                        reference-explorer-ui--docset-preview-obsolete-files
                        (list obsolete)))
          (cl-letf (((symbol-function 'xwidget-buffer)
                     (lambda (_xwidget) buffer))
                    ((symbol-function 'xwidget-webkit-callback)
                     (lambda (_xwidget _event-type)
                       (with-current-buffer buffer
                         (rename-buffer "*xwidget-webkit: docs*" t)
                         (setq xwidget-webkit--loading-p nil)))))
            (reference-explorer-ui--docset-webkit-callback
             'preview-xwidget 'load-changed))
          (should-not (file-exists-p obsolete))
          (with-current-buffer buffer
            (should (string-prefix-p " " (buffer-name)))
            (should (equal xwidget-webkit-buffer-name-format
                           reference-explorer-ui-preview-buffer-name))
            (should-not
             reference-explorer-ui--docset-preview-obsolete-files)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (file-exists-p obsolete)
        (delete-file obsolete)))))

(ert-deftest reference-explorer-ui-finds-selected-vertico-row ()
  (let ((display (concat "\nfirst\n"
                         (propertize "second\n" 'face 'vertico-current)
                         "third\n")))
    (should (= (reference-explorer-ui--vertico-selected-row display) 2))))

(ert-deftest reference-explorer-ui-extracts-selected-vertico-line ()
  (let* ((selected (propertize "second item\n" 'face 'vertico-current))
         (display (concat "\nfirst\n" selected "third\n")))
    (should (equal (reference-explorer-ui--vertico-selection display)
                   '(2 "second item")))))

(ert-deftest reference-explorer-ui-preview-uses-horizontal-space-without-overlap ()
  (let ((reference-explorer-ui-preview-max-width 80))
    (should
     (equal (reference-explorer-ui--preview-horizontal-layout
             '(1200 80 20 900) 720 9)
            '(left . 720)))
    (should (= (reference-explorer-ui--preview-left
                '(1200 80 20 900) 724 'left)
               172))
    (should
     (equal (reference-explorer-ui--preview-horizontal-layout
             '(100 80 200 10) 720 9)
            '(right . 198)))
    (should (= (reference-explorer-ui--preview-left
                '(100 80 200 10) 200 'right)
               100))))

(ert-deftest reference-explorer-ui-preview-requires-usable-horizontal-space ()
  (should-not
   (reference-explorer-ui--preview-horizontal-layout
    '(100 80 12 14) 720 180)))

(ert-deftest reference-explorer-ui-docset-preview-keeps-readable-width ()
  (should
   (= (reference-explorer-ui--preview-content-width 120 900 10 640)
      640))
  (should
   (= (reference-explorer-ui--preview-content-width 880 900 10 640)
      900)))

(ert-deftest reference-explorer-ui-preview-cleans-up-after-display-failure ()
  (let ((original-window-live-p (symbol-function 'window-live-p))
        (display-buffer-alist '(("." display-buffer-same-window)))
        (display-buffer-overriding-action
         '(display-buffer-same-window))
        render-buffer
        display-action
        display-rules
        (frame-resizes 0))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'window-live-p)
               (lambda (window)
                 (or (eq window 'anchor-window)
                     (funcall original-window-live-p window))))
              ((symbol-function 'window-frame)
               (lambda (_window) 'parent-frame))
              ((symbol-function 'frame-char-width) (lambda (_frame) 10))
              ((symbol-function 'reference-explorer-ui--render-entry)
               (lambda (_entry _name)
                 (setq render-buffer
                       (generate-new-buffer
                        " *environment-preview-display-failure*"))))
              ((symbol-function 'reference-explorer-ui--prepare-preview-buffer)
               (lambda (buffer &optional _query) buffer))
              ((symbol-function 'minibuffer-window)
               (lambda (_frame) 'minibuffer-window))
              ((symbol-function 'face-background)
               (lambda (&rest _) "white"))
              ((symbol-function 'display-buffer)
               (lambda (_buffer action)
                 (setq display-action action
                       display-rules
                       (list display-buffer-overriding-action
                             display-buffer-alist))
                 nil))
              ((symbol-function 'set-frame-size)
               (lambda (&rest _) (cl-incf frame-resizes))))
      (should-not
       (reference-explorer-ui--show-temporary-preview-at-position
        'entry '(100 80 1000 10) 'anchor-window)))
    (should-not (buffer-live-p render-buffer))
    (should (equal display-rules '(nil nil)))
    (should (memq 'display-buffer-no-window (car display-action)))
    (should (eq (alist-get 'allow-no-window (cdr display-action)) t))
    (should (= frame-resizes 0))))

(ert-deftest reference-explorer-ui-preview-measures-the-entire-buffer ()
  (let ((buffer (generate-new-buffer " *reference-explorer-ui-measure*"))
        measured)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "first\nsecond\nthird"))
          (cl-letf (((symbol-function 'window-text-pixel-size)
                     (lambda (_window from to max-width max-height &rest _)
                       (setq measured (list from to max-width max-height))
                       '(100 . 60))))
            (should
             (equal
              (reference-explorer-ui--preview-text-pixel-size
               'window buffer 800 300)
              '(100 . 60))))
          (should (equal measured '(1 19 800 300))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest reference-explorer-ui-preview-measures-wrapped-height ()
  (let ((buffer (generate-new-buffer " *reference-explorer-ui-wrap*"))
        measured)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "a long line that wraps"))
          (cl-letf (((symbol-function 'window-text-pixel-size)
                     (lambda (_window from to x-limit y-limit &rest _)
                       (setq measured (list from to x-limit y-limit))
                       '(200 . 72))))
            (should
             (= (reference-explorer-ui--preview-wrapped-height
                 'window buffer 500)
                72)))
          (should (equal measured '(1 23 nil 500))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest reference-explorer-ui-preview-aligns-with-selected-candidate ()
  (should (= (reference-explorer-ui--preview-max-height 18 1080)
             1070))
  (should (= (reference-explorer-ui--preview-top
              '(0 100 0 0) 600 1080)
             99)))

(ert-deftest reference-explorer-ui-preview-shifts-up-only-at-bottom-edge ()
  (should (= (reference-explorer-ui--preview-top
              '(0 900 0 0) 600 1080)
             476))
  (should (= (reference-explorer-ui--preview-top
              '(0 1 0 0) 600 1080)
             4)))

(ert-deftest reference-explorer-ui-preview-reserves-horizontal-slack ()
  (let ((reference-explorer-ui-preview-width-slack 2))
    (should (= (reference-explorer-ui--preview-content-width 343 720 9)
               361))
    (should (= (reference-explorer-ui--preview-content-width 715 720 9)
               720))))

(ert-deftest reference-explorer-ui-preview-omits-navigation-and-shrinks-text ()
  (let ((reference-explorer-ui-content-font-family nil)
        (buffer (generate-new-buffer " *reference-explorer-ui-preview*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "heading\nbody\n\n(前項目⇒previous)\n(次項目⇒next)\n"
                    "(全項目⇒all)\n"))
          (reference-explorer-ui--prepare-preview-buffer buffer)
          (with-current-buffer buffer
            (should (equal (buffer-string) "heading\nbody"))
            (should word-wrap)
            (should
             (= (plist-get buffer-face-mode-face :height)
                reference-explorer-ui-preview-font-height))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest reference-explorer-ui-preview-highlights-active-query ()
  (let ((reference-explorer-ui-content-font-family nil)
        (buffer (generate-new-buffer " *reference-explorer-ui-highlight*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "公爵夫人と公爵夫人"))
          (reference-explorer-ui--prepare-preview-buffer buffer "公爵夫人")
          (with-current-buffer buffer
            (should (= (point) (point-min)))
            (goto-char (point-min))
            (should
             (reference-explorer-ui--face-includes-p
              'reference-explorer-ui-preview-match
              (get-text-property (point) 'face)))
            (search-forward "公爵夫人" nil t 2)
            (backward-char 1)
            (should
             (reference-explorer-ui--face-includes-p
              'reference-explorer-ui-preview-match
              (get-text-property (point) 'face)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest reference-explorer-ui-preview-highlighting-is-source-specific ()
  (let ((reference-explorer-source-lookup-preview-highlight-sources '("encyclopedia")))
    (cl-letf (((symbol-function 'reference-explorer-source-lookup-entry-source)
               (lambda (entry)
                 (if (eq entry 'encyclopedia-entry)
                     "encyclopedia"
                   "dictionary"))))
      (should
       (equal (reference-explorer-ui--preview-query-for-entry
               'encyclopedia-entry "query")
              "query"))
      (should-not
       (reference-explorer-ui--preview-query-for-entry
        'dictionary-entry "query")))))

(ert-deftest reference-explorer-ui-quick-candidate-removes-rich-heading-display ()
  (cl-letf (((symbol-function 'lookup-entry-heading)
             (lambda (_entry)
               (propertize "　heading　" 'display '(raise -0.3))))
            ((symbol-function 'reference-explorer-source-lookup-entry-source)
             (lambda (_entry) "dictionary")))
    (let ((line (reference-explorer-ui--quick-candidate-line 'entry nil)))
      (should (equal line "heading  dictionary"))
      (should-not (get-text-property 0 'display line)))))

(ert-deftest reference-explorer-ui-applies-local-heading-filters ()
  (let ((reference-explorer-source-lookup-heading-filter-functions
         (list (lambda (entry heading)
                 (should (eq entry 'entry))
                 (concat "fixed-" heading)))))
    (cl-letf (((symbol-function 'lookup-entry-heading)
               (lambda (_entry) "heading")))
      (should (equal (reference-explorer-source-lookup--plain-entry-heading 'entry)
                     "fixed-heading")))))

(ert-deftest reference-explorer-ui-hides-expanded-heading-source-word ()
  (cl-letf (((symbol-function 'lookup-entry-heading)
             (lambda (_entry) "[renders ->] render")))
    (should (equal (reference-explorer-source-lookup--plain-entry-heading 'entry)
                   "render"))))

(ert-deftest reference-explorer-ui-keeps-ordinary-leading-underscore ()
  (cl-letf (((symbol-function 'lookup-entry-heading)
             (lambda (_entry) "_identifier")))
    (should (equal (reference-explorer-source-lookup--plain-entry-heading 'entry)
                   "_identifier"))))

(ert-deftest reference-explorer-ui-hides-consult-candidate-identity-suffix ()
  (cl-letf (((symbol-function 'reference-explorer-source-lookup--search-entries)
             (lambda (_input _mode) '(entry)))
            ((symbol-function 'lookup-entry-heading)
             (lambda (_entry)
               (propertize "　heading　" 'display '(raise -0.3))))
            ((symbol-function 'consult--tofu-append)
             (lambda (heading _id)
               (concat heading (propertize "x" 'invisible t)))))
    (let* ((candidate
            (car (reference-explorer-source-lookup--entry-candidates "query" 'literal)))
           (suffix (1- (length candidate))))
      (should-not (get-text-property 0 'display candidate))
      (should (equal (get-text-property suffix 'display candidate) "")))))

(ert-deftest reference-explorer-ui-recovers-entry-from-propertized-candidate ()
  (let ((candidate
         (concat "prefix "
                 (propertize "heading" 'consult--candidate 'entry))))
    (should (eq (reference-explorer-source-lookup-candidate-entry candidate) 'entry))))

(ert-deftest reference-explorer-ui-copies-complete-entry-description ()
  (let ((candidate (propertize "heading" 'consult--candidate 'entry))
        copied)
    (cl-letf (((symbol-function 'reference-explorer-source-lookup-entry-description)
               (lambda (_entry) "heading — source\n\ndefinition"))
              ((symbol-function 'lookup-entry-heading)
               (lambda (_entry) "heading"))
              ((symbol-function 'kill-new)
               (lambda (text &optional _replace) (setq copied text))))
      (reference-explorer-source-lookup-copy-candidate candidate)
      (should (equal copied "heading — source\n\ndefinition")))))

(ert-deftest reference-explorer-ui-exports-actionable-result-buffer ()
  (let ((first (propertize "first" 'consult--candidate 'first-entry))
        (second (propertize "second" 'consult--candidate 'second-entry))
        buffer)
    (cl-letf (((symbol-function 'lookup-entry-heading)
               (lambda (entry)
                 (if (eq entry 'first-entry) "first" "second")))
              ((symbol-function 'reference-explorer-source-lookup-entry-source)
               (lambda (entry)
                 (if (eq entry 'first-entry) "source-a" "source-b"))))
      (save-current-buffer
        (setq buffer
              (reference-explorer-source-lookup-export-candidates (list first second)))
        (should (eq (current-buffer) buffer))))
    (unwind-protect
        (with-current-buffer buffer
          (should (derived-mode-p 'reference-explorer-source-lookup-export-mode))
          (should (timerp reference-explorer-ui--export-preview-timer))
          (should (equal (buffer-string)
                         "first  source-a\nsecond  source-b\n"))
          (goto-char (point-min))
          (should (eq (reference-explorer-source-lookup--export-entry-at-point)
                      'first-entry))
          (pcase (reference-explorer-source-lookup--embark-export-target)
            (`(reference-explorer-source-lookup-entry ,candidate ,_start . ,_end)
             (should (eq (reference-explorer-source-lookup-candidate-entry candidate)
                         'first-entry)))
            (_ (ert-fail "Missing Lookup Embark target"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest reference-explorer-ui-export-preview-follows-frame-selection ()
  (with-temp-buffer
    (let ((selected 'other-frame)
          cancelled)
      (cl-letf (((symbol-function 'window-frame)
                 (lambda (_window) 'parent-frame))
                ((symbol-function 'frame-selected-window)
                 (lambda (_frame) 'export-window))
                ((symbol-function 'window-buffer)
                 (lambda (_window) (current-buffer)))
                ((symbol-function 'selected-frame)
                 (lambda () selected))
                ((symbol-function 'frame-parent)
                 (lambda (frame)
                   (and (eq frame 'preview-child) 'parent-frame)))
                ((symbol-function
                  'reference-explorer-source-lookup--export-cancel-preview)
                 (lambda () (setq cancelled t))))
        (reference-explorer-source-lookup--export-window-selection-change
         'export-window)
        (should cancelled)
        (setq cancelled nil
              selected 'preview-child)
        (reference-explorer-source-lookup--export-window-selection-change
         'export-window)
        (should-not cancelled)))))

(ert-deftest reference-explorer-ui-ranks-match-class-before-source ()
  (let ((reference-explorer-source-lookup-source-order '("preferred" "secondary")))
    (cl-letf (((symbol-function
                'reference-explorer-source-lookup--search-entries-with-method)
               (lambda (_input _mode method)
                 (pcase method
                   ('exact '((secondary . exact) (preferred . exact)))
                   ('substring
                    '((secondary . partial)
                      (secondary . exact)
                      (preferred . partial)
                      (preferred . exact))))))
              ((symbol-function 'lookup-entry-compare) #'equal)
              ((symbol-function 'lookup-entry-dictionary) #'car)
              ((symbol-function 'lookup-dictionary-title) #'symbol-name))
      (should
       (equal (reference-explorer-source-lookup--search-entries "query" 'literal)
              '((preferred . exact)
                (secondary . exact)
                (preferred . partial)
                (secondary . partial)))))))

(ert-deftest reference-explorer-ui-quick-search-uses-prefix-not-substring ()
  (let (methods)
    (cl-letf (((symbol-function
                'reference-explorer-source-lookup--search-entries-with-method)
               (lambda (_input _mode method)
                 (push method methods)
                 nil)))
      (reference-explorer-source-lookup--quick-search-entries "query")
      (should (equal (nreverse methods) '(exact prefix))))))

(ert-deftest reference-explorer-ui-quick-query-candidates-strictly-shrink ()
  (let ((reference-explorer-ui-word-candidates-function
         (lambda ()
           '("公爵夫人" "公爵夫" "爵夫人" "公爵" "爵夫" "公"))))
    (should (equal (reference-explorer-ui--quick-query-candidates-at-point)
                   '("公爵夫人" "公爵夫" "公爵" "公")))))

(ert-deftest reference-explorer-ui-quick-query-options-keep-no-match ()
  (cl-letf (((symbol-function 'reference-explorer-source-lookup--quick-search-entries)
             (lambda (query)
               (pcase query
                 ("公爵夫人" '(long-entry))
                 ("公爵" '(short-entry))))))
    (should
     (equal (reference-explorer-ui--quick-query-options
            '("公爵夫人" "公爵令嬢" "公爵")
            #'reference-explorer-source-lookup--quick-search-entries)
            '(("公爵夫人" long-entry)
              ("公爵令嬢")
              ("公爵" short-entry))))))

(ert-deftest reference-explorer-ui-quick-query-can-shrink-and-expand ()
  (let* ((session
          (reference-explorer-ui--make-quick-session
           :query "公爵夫人"
           :query-options '(("公爵夫人" long-entry)
                            ("公爵" short-entry))
           :query-index 0
           :entries '(long-entry)
           :index 0))
         (reference-explorer-ui--quick-session session)
         refreshed)
    (cl-letf (((symbol-function 'reference-explorer-ui--quick-refresh)
               (lambda (owned-session) (setq refreshed owned-session))))
      (reference-explorer-ui-quick-shorten-query)
      (should (equal (reference-explorer-ui--quick-session-query session)
                     "公爵"))
      (should (equal (reference-explorer-ui--quick-session-entries session)
                     '(short-entry)))
      (should (= (reference-explorer-ui--quick-session-query-index session) 1))
      (should (eq refreshed session))
      (reference-explorer-ui-quick-expand-query)
      (should (equal (reference-explorer-ui--quick-session-query session)
                     "公爵夫人"))
      (should (equal (reference-explorer-ui--quick-session-entries session)
                     '(long-entry))))))

(ert-deftest reference-explorer-ui-quick-lookup-starts-with-preferred-query ()
  (let (session)
    (cl-letf (((symbol-function 'lookup-initialize) #'ignore)
              ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function
                'reference-explorer-source-lookup--quick-search-entries)
               (lambda (query) (list (intern query))))
              ((symbol-function 'reference-explorer-ui--quick-open-session)
               (lambda (owned-session) (setq session owned-session))))
      (reference-explorer-source-lookup--quick-start
       '("公爵夫人" "公爵" "公") nil nil nil "公爵")
      (should (equal (reference-explorer-ui--quick-session-query session)
                     "公爵"))
      (should (= (reference-explorer-ui--quick-session-query-index session) 1))
      (should (equal (reference-explorer-ui--quick-session-entries session)
                     '(公爵))))))

(ert-deftest reference-explorer-ui-groups-partial-matches-by-source-order ()
  (let ((reference-explorer-source-lookup-source-order '("preferred" "secondary")))
    (cl-letf (((symbol-function
                'reference-explorer-source-lookup--search-entries-with-method)
               (lambda (_input _mode method)
                 (and (eq method 'substring)
                      '((other . 1)
                        (secondary . 1)
                        (preferred . 1)
                        (other . 2)
                        (preferred . 2)))))
              ((symbol-function 'lookup-entry-compare) #'equal)
              ((symbol-function 'lookup-entry-dictionary) #'car)
              ((symbol-function 'lookup-dictionary-title) #'symbol-name))
      (should
       (equal (reference-explorer-source-lookup--search-entries "query" 'literal)
              '((preferred . 1)
                (preferred . 2)
                (secondary . 1)
                (other . 1)
                (other . 2)))))))

(ert-deftest reference-explorer-ui-does-not-mutate-lookup-result-lists ()
  (let* ((reference-explorer-source-lookup--entry-cache (make-hash-table :test #'equal))
         (first-result (list 'first-entry))
         (second-result (list 'second-entry))
         (results `((first . ,first-result) (second . ,second-result))))
    (cl-letf (((symbol-function 'reference-explorer-ui--backend-query)
               (lambda (_input _mode) "query"))
              ((symbol-function 'lookup-initialize) #'ignore)
              ((symbol-function 'lookup-default-module)
               (lambda () 'module))
              ((symbol-function 'lookup-module-setup) #'ignore)
              ((symbol-function 'lookup-module-dictionaries)
               (lambda (_module) '(first second)))
              ((symbol-function 'lookup-dictionary-selected-p)
               (lambda (_dictionary) t))
              ((symbol-function 'lookup-dictionary-methods)
               (lambda (_dictionary) '(substring)))
              ((symbol-function 'lookup-make-query)
               (lambda (method string) (list method string)))
              ((symbol-function 'lookup-vse-search-query)
               (lambda (dictionary _query)
                 (cdr (assq dictionary results)))))
      (should
       (equal
        (reference-explorer-source-lookup--search-entries-with-method
         "query" 'literal 'substring)
        '(first-entry second-entry)))
      (should (equal first-result '(first-entry)))
      (should (equal second-result '(second-entry))))))

(ert-deftest reference-explorer-ui-context-search-preserves-remembered-mode ()
  (let ((reference-explorer-ui-consult-mode 'converted))
    (cl-letf (((symbol-function 'reference-explorer-source-lookup--consult-read)
               (lambda (_initial _mode) '(return nil))))
      (reference-explorer-source-lookup--consult-loop "環境" 'literal))
    (should (eq reference-explorer-ui-consult-mode 'converted))))

(ert-deftest reference-explorer-ui-consult-at-point-keeps-all-query-lengths ()
  (let (called)
    (cl-letf (((symbol-function 'lookup-initialize) #'ignore)
              ((symbol-function
                'reference-explorer-ui--quick-query-candidates-at-point)
               (lambda () '("説明文全体" "説明文" "説明")))
              ((symbol-function 'reference-explorer-source-lookup--consult-loop)
               (lambda (initial mode &optional queries)
                 (setq called (list initial mode queries)))))
      (reference-explorer-source-lookup-consult-at-point))
    (should (equal called
                   '("説明文全体" literal
                     ("説明文全体" "説明文" "説明"))))))

(ert-deftest reference-explorer-ui-thesaurus-replaces-captured-text ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "An Example remains")
    (undo-boundary)
    (let* ((beginning (copy-marker 4))
           (end (copy-marker 11 t))
           (candidate
            (reference-explorer-ui--make-thesaurus-candidate
             :result (reference-explorer-source-thesaurus-result-create :term "sample")
             :buffer (current-buffer)
             :beginning beginning
             :end end
             :original "Example")))
      (reference-explorer-ui-thesaurus-replace candidate)
      (should (equal (buffer-string) "An Sample remains"))
      (undo-boundary)
      (undo)
      (should (equal (buffer-string) "An Example remains")))))

(ert-deftest reference-explorer-ui-thesaurus-refuses-stale-replacement ()
  (with-temp-buffer
    (insert "example")
    (let ((candidate
           (reference-explorer-ui--make-thesaurus-candidate
            :result (reference-explorer-source-thesaurus-result-create :term "sample")
            :buffer (current-buffer)
            :beginning (copy-marker 1)
            :end (copy-marker 8 t)
            :original "example")))
      (goto-char (point-min))
      (delete-char 1)
      (insert "E")
      (should-error
       (reference-explorer-ui-thesaurus-replace candidate)
       :type 'user-error)
      (should (equal (buffer-string) "Example")))))

(ert-deftest reference-explorer-ui-thesaurus-preview-is-local-only ()
  (let* ((candidate
          (reference-explorer-ui--make-thesaurus-candidate
           :result (reference-explorer-source-thesaurus-result-create :term "sample")))
         searched)
    (cl-letf (((symbol-function 'lookup-initialize) #'ignore)
              ((symbol-function
                'reference-explorer-source-lookup--quick-search-entries)
               (lambda (query)
                 (setq searched query)
                 '(local-entry)))
              ((symbol-function 'reference-explorer-source-thesaurus-fetch)
               (lambda (&rest _)
                 (ert-fail "Preview performed an online search"))))
      (should (eq (reference-explorer-ui--candidate-preview-entry candidate)
                  'local-entry))
      (should (equal searched "sample")))))

(ert-deftest reference-explorer-ui-thesaurus-preview-honors-source-order ()
  (let* ((reference-explorer-source-lookup-thesaurus-preview-sources
          '("preferred" "fallback"))
         (candidate
          (reference-explorer-ui--make-thesaurus-candidate
           :result (reference-explorer-source-thesaurus-result-create :term "sample"))))
    (cl-letf (((symbol-function 'lookup-initialize) #'ignore)
              ((symbol-function
                'reference-explorer-source-lookup--quick-search-entries)
               (lambda (_query) '(other-entry fallback-entry preferred-entry)))
              ((symbol-function 'reference-explorer-source-lookup-entry-source)
               (lambda (entry)
                 (pcase entry
                   ('preferred-entry "preferred")
                   ('fallback-entry "fallback")
                   (_ "other")))))
      (should
       (eq (reference-explorer-ui--candidate-preview-entry candidate)
           'preferred-entry)))))

(ert-deftest reference-explorer-ui-thesaurus-preview-can-exclude-all-sources ()
  (let* ((reference-explorer-source-lookup-thesaurus-preview-sources '("unavailable"))
         (candidate
          (reference-explorer-ui--make-thesaurus-candidate
           :result (reference-explorer-source-thesaurus-result-create :term "sample"))))
    (cl-letf (((symbol-function 'lookup-initialize) #'ignore)
              ((symbol-function
                'reference-explorer-source-lookup--quick-search-entries)
               (lambda (_query) '(entry)))
              ((symbol-function 'reference-explorer-source-lookup-entry-source)
               (lambda (_entry) "other")))
      (should-not
       (reference-explorer-ui--candidate-preview-entry candidate)))))

(ert-deftest reference-explorer-ui-thesaurus-list-shows-only-terms ()
  (let ((candidate
         (reference-explorer-ui--make-thesaurus-candidate
          :result
          (reference-explorer-source-thesaurus-result-create
           :term "sample" :rating 91 :votes 12))))
    (should (equal (reference-explorer-ui--candidate-label candidate)
                   "sample"))
    (should (string-empty-p
             (reference-explorer-ui--candidate-annotation candidate)))
    (should (equal (reference-explorer-ui--quick-candidate-line
                    candidate nil)
                   "sample"))))

(ert-deftest reference-explorer-ui-docset-kind-normalizes-common-plurals ()
  (should (eq (reference-explorer-ui--docset-kind-symbol "Methods") 'method))
  (should (eq (reference-explorer-ui--docset-kind-symbol "Attributes")
              'attribute))
  (should (eq (reference-explorer-ui--docset-kind-symbol "Classes") 'class))
  (should (eq (reference-explorer-ui--docset-kind-symbol "Properties")
              'property))
  (should (eq (reference-explorer-ui--docset-corfu-kind "Attributes")
              'field))
  (should (eq (reference-explorer-ui--docset-corfu-kind "Guide") 'text))
  (should (eq (reference-explorer-ui--docset-corfu-kind "Protocol")
              'interface)))

(ert-deftest reference-explorer-ui-docset-kind-has-text-fallback ()
  (should (equal (substring-no-properties
                  (reference-explorer-ui--docset-kind-fallback "Method"))
                 "[Method] "))
  (should (equal (substring-no-properties
                  (reference-explorer-ui--docset-kind-fallback nil))
                 "[Reference] ")))

(ert-deftest reference-explorer-ui-single-docset-list-hides-source-version ()
  (let* ((docset (reference-explorer-source-docset-create
                  :name "Ruby-4.0.6" :feed "Ruby" :version "4.0.6"))
         (result (reference-explorer-source-docset-result-create
                  :name "Kernel.require" :type "Method" :docset docset)))
    (cl-letf (((symbol-function 'reference-explorer-ui--docset-kind-icon)
               (lambda (_type) "I ")))
      (should (equal (reference-explorer-ui--candidate-annotation result)
                     "I "))
      (should (equal (reference-explorer-ui--quick-candidate-line result nil)
                     "I Kernel.require"))
      (should (equal
               (reference-explorer-ui--quick-candidate-line result nil t)
               "I Kernel.require  Ruby")))))

(ert-deftest reference-explorer-ui-thesaurus-starts-one-explicit-fetch ()
  (with-temp-buffer
    (insert "replace example here")
    (goto-char 9)
    (push-mark 16 t t)
    (let ((transient-mark-mode t)
          fetches
          shown)
      (cl-letf (((symbol-function 'reference-explorer-source-thesaurus-fetch)
                 (lambda (query type success &optional _failure)
                   (push (list query type) fetches)
                   (funcall
                    success
                    (list
                     (reference-explorer-source-thesaurus-result-create
                      :term "sample")))))
                ((symbol-function
                  'reference-explorer-ui--thesaurus-show-targets)
                 (lambda (query targets _window _marker _bounds)
                   (setq shown (list query targets)))))
        (reference-explorer-ui-thesaurus-at-point))
      (should (equal fetches '(("example" synonyms))))
      (should (equal (car shown) "example"))
      (should
       (equal
        (reference-explorer-ui--thesaurus-candidate-original
         (car (cadr shown)))
        "example")))))

(ert-deftest reference-explorer-ui-thesaurus-embark-default-is-replacement ()
  (unless (require 'embark nil t)
    (ert-skip "Embark is unavailable"))
  (should
   (eq (alist-get 'reference-explorer-source-thesaurus-candidate
                  embark-default-action-overrides)
       #'reference-explorer-ui-thesaurus-replace))
  (should
   (eq (lookup-key reference-explorer-ui-thesaurus-embark-map (kbd "l"))
       #'reference-explorer-ui-thesaurus-lookup))
  (should
   (eq (lookup-key reference-explorer-ui-thesaurus-embark-map (kbd "s"))
       #'reference-explorer-ui-thesaurus-search-candidate)))

(provide 'reference-explorer-ui-test)
;;; reference-explorer-ui-test.el ends here
