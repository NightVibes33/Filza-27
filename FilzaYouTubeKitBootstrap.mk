# Bootstrap the pinned pre-v2.4 ByeTunes YouTubeKit source tree before Theos
# expands/validates FilzaApplySandboxExt_SWIFT_FILES.
#
# The normal before-FilzaApplySandboxExt-all hook is too late for a source tree
# that does not exist in a fresh checkout: Theos can reject the missing Swift
# inputs before that hook gets a chance to stage them. Keep clean-only commands
# side-effect free, but make every real build self-contained.

BYETUNES_YTK_BOOTSTRAP_ROOT := ThirdParty/byetunes-youtubekit/Generated
BYETUNES_YTK_BOOTSTRAP_SENTINEL := $(BYETUNES_YTK_BOOTSTRAP_ROOT)/Cipher.swift

ifneq ($(strip $(MAKECMDGOALS)),clean)
ifeq ($(wildcard $(BYETUNES_YTK_BOOTSTRAP_SENTINEL)),)
BYETUNES_YTK_BOOTSTRAP_STATUS := $(shell bash scripts/stage-byetunes-youtubekit.sh >/dev/null 2>&1 && echo ready || echo failed)
ifeq ($(BYETUNES_YTK_BOOTSTRAP_STATUS),failed)
$(error Failed to stage pinned ByeTunes YouTubeKit before Theos source validation)
endif
endif
endif
