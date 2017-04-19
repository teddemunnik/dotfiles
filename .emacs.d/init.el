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

;; Save recently opened files
(require 'recentf)
(recentf-mode 1)
(setq recentf-max-menu-items 25)

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
    (setq evil-want-C-u-scroll t)
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

(set-face-attribute 'default nil
		    :family "Source Code Pro"
		    :height 120
		    :weight 'normal
		    :width 'normal)

;; General key bindings
(setq my-leader "SPC")
(use-package general
  :ensure t
  :init (progn
	  (setq general-default-keymaps 'evil-normal-state-map)
	  (general-define-key
	   "j" 'evil-next-visual-line
	   "k" 'evil-previous-visual-line)))

;; Projectile
(use-package projectile
  :ensure t
  :init (projectile-mode)
  :config (progn
            (general-define-key :prefix my-leader "pc" 'projectile-compile-project)))

;; Helm
(use-package helm
  :ensure t
  :config (progn
	    (general-define-key :keymaps 'helm-map "C-j" 'helm-next-line)
	    (general-define-key :keymaps 'helm-map "C-k" 'helm-previous-line)
	    (general-define-key :keymaps 'helm-map "<escape>" 'helm-keyboard-quit)
	    (general-define-key :prefix my-leader "ff" 'helm-find-files)
        (general-define-key :prefix my-leader "fr" 'helm-recentf)
	    ))
(use-package helm-ag
  :ensure t)
(use-package helm-projectile
  :ensure t
  :config (progn
            (general-define-key :prefix my-leader "pp" 'helm-projectile-switch-project)
            (general-define-key :prefix my-leader "fg" 'helm-projectile-ag)
            (general-define-key :prefix my-leader "pf" 'helm-projectile-find-file)))

(setq-default c-basic-offset 4
	      tab-width 4
	      indent-tabs-mode nil)
