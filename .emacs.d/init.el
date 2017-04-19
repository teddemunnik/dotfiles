;; Disable unneccesary UI elements early to avoid it showing up momentarily
(menu-bar-mode -1)
(scroll-bar-mode -1)
(tool-bar-mode -1)
(setq inhibit-startup-message 1)
(setq sentence-end-double-space nil)

;; Place backups in a specified directory
(setq backup-directory-alist '(("." . "~/.emacs.d/backups")))
(setq delete-old-versions -1)
(setq version-control t)
(setq vc-make-backup-files t)
(setq auto-save-file-name-transforms '((".*" "~/.emacs.d/auto-save-list/" t)))

;; Save command history so that undo works across saves
(setq savehist-file "~/.emacs.d/savehist")
(savehist-mode +1)
(setq savehist-save-minibuffer-history +1)
(setq savehist-additional-variables '(kill-ring search-ring regexp-search-ring))

(require 'package)
(setq package-enable-at-startup nil)
(add-to-list 'package-archives
             '("melpa" . "http://melpa.org/packages/"))

(package-initialize)

;; Bootstrap `use-package'
(unless (package-installed-p 'use-package)
  (package-refresh-contents)
  (package-install 'use-package))

(eval-when-compile
  (require 'use-package))


(use-package evil
  :ensure t
  :init
  (progn
    (setq evil-default-cursor t)
    (evil-mode 1)
    )
 )

(use-package monokai-theme
  :ensure t
  :init (load-theme 'monokai t))

(blink-cursor-mode 0)
(global-linum-mode 1)
(use-package linum-relative
  :ensure t
  :config (progn
	    (setq linum-relative-format "%3s ")
	    (setq linum-relative-current-symbol "")
	    (linum-relative-on)))

;; General key bindings
(setq my-leader "SPC")
(use-package general
  :ensure t
  :init (progn
	  (setq general-default-keymaps 'evil-normal-state-map)
	  (general-define-key
	   "j" 'evil-next-visual-line
	   "k" 'evil-previous-visual-line)

	  (general-define-key :prefix my-leader "ff" 'helm-find-files)))

;; Projectile
(use-package projectile
  :ensure t
  :init (progn
	  (general-define-key :prefix my-leader "fF" 'projectile-find-file)))

;; Helm
(use-package helm
  :ensure t)
(use-package helm-ag
  :ensure t)
(use-package helm-projectile
  :ensure t
  :init (progn
	  (general-define-key :prefix my-leader "fg" 'helm-projectile-ag)))

