{ config, lib, pkgs, ... }:
let
  cfg = config.programs.claude-token-tools;

  defaultPackage = pkgs.writeShellScriptBin "claude-model-usage" ''
    exec ${pkgs.bun}/bin/bun run ${../skills/model-usage/audit.bundle.js} "$@"
  '';

  settingsPatch = {
    model = cfg.model;
    effortLevel = cfg.effortLevel;
    autoCompactEnabled = true;
    skillListingMaxDescChars = 256;
    fastModePerSessionOptIn = true;
    enableAllProjectMcpServers = false;
    env = {
      CLAUDE_CODE_SUBAGENT_MODEL = cfg.subagentModel;
      CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = toString cfg.autoCompactPct;
    };
  };

  mergeScript = pkgs.writeShellScript "claude-token-tools-merge-settings" ''
    set -euo pipefail
    f="$1"
    tmp=$(mktemp "''${f}.XXXXXX")
    # Merge token-saving keys into ~/.claude/settings.json.
    # Uses jq object-merge (* operator): scalars and env keys are additive;
    # existing hooks, theme, plugins, and permissions are untouched.
    ${pkgs.jq}/bin/jq \
      --argjson patch ${lib.strings.escapeShellArg (builtins.toJSON settingsPatch)} \
      '. * ($patch | .env = ((.env // {}) * $patch.env))' \
      "$f" > "$tmp" && mv "$tmp" "$f"
  '';
in {
  options.programs.claude-token-tools = {
    enable = lib.mkEnableOption "Claude Code token-saving toolkit";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "pkgs.writeShellScriptBin \"claude-model-usage\" \"...\"";
      description = "The claude-model-usage CLI package.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "sonnet";
      description = "Default Claude model written into ~/.claude/settings.json.";
    };

    effortLevel = lib.mkOption {
      type = lib.types.enum [ "low" "medium" "high" "xhigh" ];
      default = "medium";
    };

    subagentModel = lib.mkOption {
      type = lib.types.str;
      default = "claude-haiku-4-5-20251001";
    };

    autoCompactPct = lib.mkOption {
      type = lib.types.int;
      default = 70;
      description = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE value (0–100).";
    };

    capVerboseBash = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Deploy the PreToolUse Bash output-cap hook to ~/.claude/hooks/.";
      };
    };

    stampAccount = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Deploy the SessionStart account-stamp hook to ~/.claude/hooks/.";
      };
    };

    weeklyAudit = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the Monday 09:00 launchd audit agent.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    # Deploy hook and skill files to ~/.claude/.
    # A cleanup activation step (below) removes any pre-existing regular files
    # before linkGeneration so home-manager can place its store symlinks.
    home.file = lib.mkMerge [
      (lib.mkIf cfg.capVerboseBash.enable {
        ".claude/hooks/cap-verbose-bash.sh" = {
          source = ../hooks/cap-verbose-bash.sh;
          executable = true;
        };
      })
      (lib.mkIf cfg.stampAccount.enable {
        ".claude/hooks/stamp-account.sh" = {
          source = ../hooks/stamp-account.sh;
          executable = true;
        };
      })
      (lib.mkIf cfg.weeklyAudit.enable {
        ".claude/scripts/model-usage-audit.sh" = {
          source = ../scripts/model-usage-audit.sh;
          executable = true;
        };
      })
      {
        ".claude/skills/model-usage/audit.ts".source      = ../skills/model-usage/audit.ts;
        ".claude/skills/model-usage/audit.bundle.js".source = ../skills/model-usage/audit.bundle.js;
        ".claude/skills/model-usage/package.json".source  = ../skills/model-usage/package.json;
        ".claude/skills/model-usage/SKILL.md".source      = ../skills/model-usage/SKILL.md;
      }
    ];

    launchd.agents.claude-model-usage-audit = lib.mkIf cfg.weeklyAudit.enable {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/bash"
          "${config.home.homeDirectory}/.claude/scripts/model-usage-audit.sh"
        ];
        StartCalendarInterval = [{ Weekday = 1; Hour = 9; Minute = 0; }];
        StandardOutPath = "${config.home.homeDirectory}/.claude/model-usage-audit.out";
        StandardErrorPath = "${config.home.homeDirectory}/.claude/model-usage-audit.err";
      };
    };

    # Remove working-copy files before checkLinkTargets so home-manager can
    # place nix store symlinks without conflict errors.
    home.activation.claudeTokenToolsCleanup =
      lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
        for f in \
          "${config.home.homeDirectory}/.claude/hooks/cap-verbose-bash.sh" \
          "${config.home.homeDirectory}/.claude/hooks/stamp-account.sh" \
          "${config.home.homeDirectory}/.claude/scripts/model-usage-audit.sh" \
          "${config.home.homeDirectory}/.claude/skills/model-usage/audit.ts" \
          "${config.home.homeDirectory}/.claude/skills/model-usage/audit.bundle.js" \
          "${config.home.homeDirectory}/.claude/skills/model-usage/package.json" \
          "${config.home.homeDirectory}/.claude/skills/model-usage/SKILL.md"; do
          # Only remove regular files; leave existing nix symlinks alone.
          [ -L "$f" ] || $DRY_RUN_CMD rm -f "$f"
        done
        # node_modules is incompatible with a nix-store-symlinked bundle; remove.
        $DRY_RUN_CMD rm -rf "${config.home.homeDirectory}/.claude/skills/model-usage/node_modules"
      '';

    # Merge token-saving settings into ~/.claude/settings.json (additive — does
    # not overwrite hooks, theme, plugins, or permissions already present).
    home.activation.claudeTokenToolsSettings =
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        _settingsFile="${config.home.homeDirectory}/.claude/settings.json"
        $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.claude"
        if [ ! -f "$_settingsFile" ]; then
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/printf '%s\n' '{}' > "$_settingsFile"
        fi
        $DRY_RUN_CMD ${mergeScript} "$_settingsFile"
      '';
  };
}
