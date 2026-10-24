;; What guix-subs builds nightly: a qubes-guix template like the one
;; qubes-guix-install makes (xterm, no desktop, one user), so the Qubes
;; agents are already built when a template updates. It's never booted:
;; only the store items matter, so host name, user etc. don't.

(use-modules (gnu) (guix channels) (qubes system))
(use-service-modules desktop)
(use-package-modules xorg)

(qubes-operating-system
 (operating-system
   (locale "en_US.utf8")
   (timezone "UTC")
   (host-name "guix")
   (users (cons (user-account
                 (name "user")
                 (group "users")
                 (supplementary-groups '("wheel" "netdev" "audio" "video")))
                %base-user-accounts))
   (packages (cons xterm %base-packages))
   (services %desktop-services)
   (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets '("/dev/xvda"))))
   (file-systems (cons (file-system
                         (mount-point "/")
                         (device (file-system-label "guix-root"))
                         (type "ext4"))
                       %base-file-systems)))
 #:template? #t
 #:extra-packages '("git"))
