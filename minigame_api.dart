// ============================================================
// NotSelf — Minigame API  (Bridge Layer)
// Mozilla Public License 2.0 — see LICENSE in repo root.
//
// Isolates all NotSelf minigames from the host application.
// Minigames communicate ONLY through this contract — they have
// zero knowledge of the host app's models, database, or auth.
// A developer with only this file + MINIGAME_DEVELOPER_DOCS.md
// can build a fully compatible, privacy-safe minigame.
//
// DESIGN PRINCIPLE — Privacy by Architecture:
//   Raw session responses never leave the minigame. Only the
//   final output label (e.g. parts_band) exits via MinigameResult.
//   This is not a policy — it is enforced by the API shape itself.
//
// ARCHITECTURE:
//   NotSelf Host App  (or any Flutter app / browser SDK)
//       ↕  NotSelf Minigame API  (this file — the only contract)
//       ↕  Individual Minigame Screens  (standalone projects)
//
// Each minigame receives a MinigameSession on launch and returns
// a MinigameResult on completion. The host app handles all
// persistence — minigames are stateless by design.
//
// ANIMATION CONTRACT:
//   Minigames MUST use MinigameSession.animationConfig to drive
//   their particle field, orb bob amplitude, and phase transition
//   timing. This ensures visual coherence across all minigames.
//   Minigames MUST call session.onPhaseChange(phase) whenever
//   the active phase changes — this lets the host app synchronise
//   ambient effects overlaid on top of the minigame.
// ============================================================

import 'dart:math' as math;
import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────
// DATA CLASSES — Session input and result output contracts
// All types are plain Dart — no host-app imports required.
// ─────────────────────────────────────────────────────────────

/// Read-only snapshot of an IFS part (rendered as a character)
/// passed into a minigame session. Minigames MUST NOT import
/// models.dart — use this self-contained representation instead.
///
/// In the NotSelf IFS model, each character represents an inner
/// part (Manager, Firefighter, Exile, or Self). The minigame uses
/// this data to personalise prompts without touching the host DB.
class MinigameCharacter {
  final String id;
  final String characterName;
  final String role;
  final String backstory;
  final String bodyRegion;
  final String sensation;
  final String element;
  final String emotionFamily;
  final int level;
  final int breathingSessions; // prior grounding sessions with this part
  final String? spriteBodyPath; // file path to body sprite image, or null
  final String? spriteBackgroundPath;
  /// All sprite layer image paths keyed by SpriteLayer.name
  /// (e.g. "bodyBase", "head", "bgPast", "background", "bgFuture").
  ///
  /// IMPORTANT: Only include layers that have a real file path.
  /// Bezier/stroke-drawn layers have no image file and must be
  /// excluded from this map (empty-string paths cause Image.file
  /// failures). Use [sanitizeSpriteLayers] when building this from
  /// a CharacterSprite to strip out empty paths automatically.
  final Map<String, String> spriteLayers;
  final Color elementColor;

  /// Pre-parsed body region data — regions + per-region direction angles.
  /// Extracted from [bodyRegion] by the app before launching so minigames
  /// never need to import card_body_map.dart.
  ///
  /// Structure: list of (label, normalised Offset, optional angle) triples.
  /// Use [MinigameBodyMap] widget to render this visually.
  final List<MinigameBodyRegion> bodyRegions;

  const MinigameCharacter({
    required this.id,
    required this.characterName,
    required this.role,
    required this.backstory,
    required this.bodyRegion,
    required this.sensation,
    required this.element,
    required this.emotionFamily,
    required this.level,
    required this.breathingSessions,
    this.spriteBodyPath,
    this.spriteBackgroundPath,
    this.spriteLayers = const {},
    required this.elementColor,
    this.bodyRegions = const [],
  });

  /// Strip empty-path entries from a sprite-layer map.
  ///
  /// Bezier/stroke-drawn layers have no exported image file so their
  /// [imagePath] is an empty string. Passing those to [Image.file] causes
  /// silent render failures. Call this when constructing [MinigameCharacter]:
  ///
  /// ```dart
  /// spriteLayers: MinigameCharacter.sanitizeSpriteLayers(rawLayerMap),
  /// ```
  static Map<String, String> sanitizeSpriteLayers(Map<String, String> raw) =>
      Map.fromEntries(
        raw.entries.where((e) => e.value.isNotEmpty),
      );

  /// Convenience: build [bodyRegions] from a raw [bodyRegion] string.
  ///
  /// Call this in the app when constructing [MinigameCharacter] so that
  /// all minigames receive pre-resolved region data:
  ///
  /// ```dart
  /// MinigameCharacter(
  ///   ...
  ///   bodyRegions: MinigameCharacter.resolveRegions(card.bodyRegion),
  /// )
  /// ```
  static List<MinigameBodyRegion> resolveRegions(String raw) {
    if (raw.isEmpty) return const [];

    // ── Parse angles ─────────────────────────────────────────
    final Map<String, double> labelAngles = {};
    final List<String> cleanLabels = [];

    if (raw.contains('|')) {
      // New per-region format: "Label1::angle1|Label2::angle2"
      for (final entry in raw.split('|')) {
        final sep = entry.indexOf('::');
        if (sep == -1) {
          final t = entry.trim();
          if (t.isNotEmpty) cleanLabels.add(t);
        } else {
          final label = entry.substring(0, sep).trim();
          final angle = double.tryParse(entry.substring(sep + 2).trim());
          if (label.isNotEmpty) {
            cleanLabels.add(label);
            if (angle != null) labelAngles[label] = angle;
          }
        }
      }
    } else {
      // Old format: "Label1, Label2::singleAngle"
      final sep = raw.lastIndexOf('::');
      final regionPart = sep == -1 ? raw : raw.substring(0, sep).trim();
      final singleAngle =
          sep == -1 ? null : double.tryParse(raw.substring(sep + 2).trim());
      for (final r in regionPart.split(',')) {
        final t = r.trim();
        if (t.isNotEmpty) {
          cleanLabels.add(t);
          if (singleAngle != null) labelAngles[t] = singleAngle;
        }
      }
    }

    // ── Resolve positions ────────────────────────────────────
    final result = <MinigameBodyRegion>[];
    for (final label in cleanLabels) {
      final key = label.toLowerCase();
      Offset? pos = _kBodyRegionPositions[key];
      if (pos == null) {
        for (final e in _kBodyRegionPositions.entries) {
          if (key.contains(e.key) || e.key.contains(key)) {
            pos = e.value;
            break;
          }
        }
      }
      if (pos == null) continue;
      // Look up angle case-insensitively
      double? angle = labelAngles[label];
      if (angle == null) {
        for (final e in labelAngles.entries) {
          if (e.key.toLowerCase() == key) {
            angle = e.value;
            break;
          }
        }
      }
      result.add(MinigameBodyRegion(
        label: label,
        nx: pos.dx,
        ny: pos.dy,
        angleRadians: angle,
      ));
    }
    return result;
  }

  // Normalised silhouette positions — mirrors card_body_map.dart so
  // the API is self-contained. Minigames never need to import that file.
  static const Map<String, Offset> _kBodyRegionPositions = {
    'head': Offset(0.50, 0.05), 'skull': Offset(0.50, 0.04),
    'face': Offset(0.50, 0.07), 'eyes': Offset(0.50, 0.05),
    'forehead': Offset(0.50, 0.03), 'jaw': Offset(0.50, 0.13),
    'neck': Offset(0.50, 0.18), 'throat': Offset(0.50, 0.19),
    'shoulders': Offset(0.50, 0.25),
    'left shoulder': Offset(0.22, 0.24), 'right shoulder': Offset(0.78, 0.24),
    'chest': Offset(0.50, 0.31), 'heart': Offset(0.40, 0.30),
    'left chest': Offset(0.38, 0.30), 'right chest': Offset(0.62, 0.30),
    'upper back': Offset(0.50, 0.33), 'back': Offset(0.50, 0.33),
    'left arm': Offset(0.11, 0.40), 'right arm': Offset(0.89, 0.40),
    'left forearm': Offset(0.10, 0.47), 'right forearm': Offset(0.90, 0.47),
    'left elbow': Offset(0.11, 0.44), 'right elbow': Offset(0.89, 0.44),
    'left wrist': Offset(0.10, 0.52), 'right wrist': Offset(0.90, 0.52),
    'left hand': Offset(0.09, 0.56), 'right hand': Offset(0.91, 0.56),
    'solar plexus': Offset(0.50, 0.39), 'diaphragm': Offset(0.50, 0.40),
    'stomach': Offset(0.50, 0.43), 'gut': Offset(0.50, 0.46),
    'belly': Offset(0.50, 0.44), 'abdomen': Offset(0.50, 0.46),
    'lower back': Offset(0.50, 0.48),
    'pelvis': Offset(0.50, 0.54), 'hips': Offset(0.50, 0.55),
    'groin': Offset(0.50, 0.57),
    'left hip': Offset(0.35, 0.57), 'right hip': Offset(0.65, 0.57),
    'left thigh': Offset(0.35, 0.66), 'right thigh': Offset(0.65, 0.66),
    'left knee': Offset(0.35, 0.76), 'right knee': Offset(0.65, 0.76),
    'left shin': Offset(0.34, 0.85), 'right shin': Offset(0.66, 0.85),
    'left calf': Offset(0.34, 0.87), 'right calf': Offset(0.66, 0.87),
    'left ankle': Offset(0.35, 0.93), 'right ankle': Offset(0.65, 0.93),
    'left foot': Offset(0.35, 0.97), 'right foot': Offset(0.65, 0.97),
  };
}

/// A single resolved body region — label, normalised position on the
/// silhouette (0–1 both axes), and optional outward direction angle.
class MinigameBodyRegion {
  /// Human-readable label, e.g. "Left Shoulder".
  final String label;

  /// Normalised (x, y) on the silhouette canvas (0–1 both axes).
  final double nx;
  final double ny;

  /// Outward arrow direction in radians (Flutter math convention).
  /// null = no arrow.
  final double? angleRadians;

  const MinigameBodyRegion({
    required this.label,
    required this.nx,
    required this.ny,
    this.angleRadians,
  });
}

// ─────────────────────────────────────────────────────────────
// ANIMATION CONFIG — Visual coherence across all NotSelf minigames
// ─────────────────────────────────────────────────────────────

/// Visual animation parameters derived from the host context
/// (sanctuary theme, part element, user prefs) and forwarded
/// to each minigame so they match NotSelf's visual language without
/// importing AppTheme or animation_helpers directly.
///
/// All minigames MUST respect these values — never hardcode
/// particle counts, bob amplitudes, or transition durations.
/// This is what makes every minigame feel like one coherent product.
class MinigameAnimationConfig {
  // ── Particles ──────────────────────────────────────────────

  /// Number of ambient particles to spawn.
  /// Active-session default: 40. Pre-session / idle: 15.
  final int particleCountIdle;
  final int particleCountActive;

  /// Particle shape key. Maps to ParticleShape in animation_helpers:
  ///   'dot'  → default theme (simple circles, rise upward)
  ///   'leaf' → zen_garden (curvy zigzag wind)
  ///   'star' → cosmic_nebula (orbit + drift)
  final String particleShape;

  // ── Sprite bob ─────────────────────────────────────────────

  /// Idle bob amplitude in logical pixels (pre-session).
  final double spriteBobAmplitudeIdle;

  /// Active bob amplitude in logical pixels (during session).
  final double spriteBobAmplitudeActive;

  // ── Orb ────────────────────────────────────────────────────

  /// Whether the inquiry orb should show a pulsing outer glow.
  /// Disable for low-power / accessibility modes.
  final bool orbPulseEnabled;

  /// Multiplier applied to all per-phase orb scale durations.
  /// 1.0 = normal speed; < 1 = faster; > 1 = slower.
  /// Useful for guided vs free-form sessions.
  final double orbSpeedMultiplier;

  // ── Phase transitions ──────────────────────────────────────

  /// Curve key for phase-label and question fade transitions.
  ///   'easeInOut'    → default
  ///   'easeOutCubic' → snappier
  ///   'elasticOut'   → bouncy (playful themes)
  ///   'linear'       → mechanical / debug
  final String transitionCurveKey;

  /// Duration multiplier for all AnimatedContainer / AnimatedSwitcher
  /// transitions inside the minigame.  1.0 = normal; < 1 = faster.
  final double transitionSpeedMultiplier;

  // ── Completion ─────────────────────────────────────────────

  /// Whether to show the slide-in completion card.
  final bool showCompletionCard;

  /// Duration of the completion slide-in animation.
  final Duration completionAnimDuration;

  const MinigameAnimationConfig({
    this.particleCountIdle = 15,
    this.particleCountActive = 40,
    this.particleShape = 'dot',
    this.spriteBobAmplitudeIdle = 3.0,
    this.spriteBobAmplitudeActive = 6.0,
    this.orbPulseEnabled = true,
    this.orbSpeedMultiplier = 1.0,
    this.transitionCurveKey = 'easeInOut',
    this.transitionSpeedMultiplier = 1.0,
    this.showCompletionCard = true,
    this.completionAnimDuration = const Duration(milliseconds: 600),
  });

  /// Resolve the Dart Curve from the stored key.
  Curve get transitionCurve {
    switch (transitionCurveKey) {
      case 'easeOutCubic':
        return Curves.easeOutCubic;
      case 'elasticOut':
        return Curves.elasticOut;
      case 'linear':
        return Curves.linear;
      case 'easeOut':
        return Curves.easeOut;
      case 'easeIn':
        return Curves.easeIn;
      default:
        return Curves.easeInOut;
    }
  }

  /// Convenience: derive a config from a sanctuary theme name.
  /// Call this in the host app when building MinigameSession so
  /// minigames get a contextually appropriate visual config without
  /// needing to import AppTheme.
  factory MinigameAnimationConfig.fromContext({
    String sanctuaryTheme = 'default',
  }) {
    final String shape;
    switch (sanctuaryTheme) {
      case 'zen_garden':
        shape = 'leaf';
        break;
      case 'cosmic_nebula':
        shape = 'star';
        break;
      default:
        shape = 'dot';
    }

    return MinigameAnimationConfig(
      particleShape: shape,
      transitionCurveKey:
          sanctuaryTheme == 'cosmic_nebula' ? 'easeOutCubic' : 'easeInOut',
    );
  }

  /// Default config — used when no sanctuary theme is available.
  static const MinigameAnimationConfig defaults = MinigameAnimationConfig();
}

// ─────────────────────────────────────────────────────────────
// SESSION — Configuration passed to a NotSelf minigame on launch
//
// Privacy guarantee: the session carries only what the minigame
// needs to run. No user identity, no raw history, no PII.
// The minigame scores locally and returns a label — nothing more.
// ─────────────────────────────────────────────────────────────

/// Session configuration passed to a NotSelf minigame on launch.
/// Carries part data, timing, personality signals, and animation
/// config — everything the minigame needs, nothing it doesn't.
class MinigameSession {
  /// The IFS part (rendered as a character) this session is focused on
  final MinigameCharacter character;

  /// Session timing defaults (minigame can override internally)
  final int recallSeconds;
  final int embodySeconds;
  final int inquireSeconds;
  final int listenSeconds;
  final int cycleCount;

  /// Total seconds the user has spent with this part across all sessions.
  /// Used to personalise prompts — longer relationship = richer context.
  final int priorHangoutSeconds;

  /// Part personality parameters (0.0–1.0 each) — derived from the
  /// IFS part's archetype and the user's interaction history.
  /// Minigames may use these to shade prompt tone or pacing.
  final double openness;
  final double energy;
  final double warmth;
  final double resistance;
  final double playfulness;

  /// The reaction emoji pool this part uses for in-session feedback.
  final List<String> reactionPool;

  /// Callback: request a contextual reaction emoji for the current phase.
  /// Pass the phase name ('recall', 'embody', 'inquire', 'listen', 'idle').
  /// Returns an emoji string drawn from the part's personality pool.
  final String Function(String phase)? requestReaction;

  /// Visual animation config derived from the current sanctuary theme
  /// and user preferences. Minigames MUST use this to drive their
  /// particle fields, orb, and transition durations — never hardcode.
  final MinigameAnimationConfig animationConfig;

  /// Optional callback: fired by the minigame whenever the active
  /// phase changes. Receives the new phase name as a string.
  /// Use this to synchronise ambient overlay effects in the host app.
  ///
  /// Phase names: 'ready', 'recall', 'embody', 'inquire', 'listen',
  ///              'complete', 'paused', 'cancelled'
  ///
  /// NOTE: Runs on the UI thread — keep it fast and non-blocking.
  final void Function(String phase)? onPhaseChange;

  // ── In-game navigation ─────────────────────────────────────

  /// Bottom navigation tabs to show inside the minigame shell.
  /// The minigame reads this list to build its tab bar.
  /// If null, the minigame uses its built-in default tabs.
  ///
  /// Standard keys: 'activity', 'leaderboard', 'skills', 'settings'.
  /// Minigame developers can define custom keys for their own tabs
  /// without modifying the screen itself.
  final List<MinigameBottomTab>? bottomTabs;

  /// Leaderboard data: all characters this user has interacted with,
  /// sorted descending by hangout time. Includes the current character.
  /// If empty the leaderboard tab loads from providers directly.
  final List<MinigameLeaderboardEntry> leaderboardEntries;

  const MinigameSession({
    required this.character,
    this.recallSeconds = 12,
    this.embodySeconds = 12,
    this.inquireSeconds = 12,
    this.listenSeconds = 12,
    this.cycleCount = 1,
    this.priorHangoutSeconds = 0,
    this.openness = 0.5,
    this.energy = 0.5,
    this.warmth = 0.5,
    this.resistance = 0.5,
    this.playfulness = 0.5,
    this.reactionPool = const [],
    this.requestReaction,
    this.animationConfig = MinigameAnimationConfig.defaults,
    this.onPhaseChange,
    this.bottomTabs,
    this.leaderboardEntries = const [],
  });
}

// ─────────────────────────────────────────────────────────────
// BOTTOM NAVIGATION — Tab definitions for the in-game nav bar
// ─────────────────────────────────────────────────────────────

/// Defines a single tab in a NotSelf minigame's bottom nav bar.
/// The host supplies a list via [MinigameSession.bottomTabs]
/// to customise what appears at the bottom of the minigame.
///
/// Standard keys (used by BreathingSessionScreen defaults):
///   'activity'    — the main session view
///   'leaderboard' — time-with-parts rankings
///   'skills'      — skill tree
///   'settings'    — session settings (phase timing + cycle count)
///
/// NOTE: The legacy key 'extra' (previously "Coming Soon") has been
/// replaced by 'settings'. Update any custom bottomTabs lists
/// that referenced 'extra' to use 'settings' instead.
class MinigameBottomTab {
  /// Unique key for this tab. Used for equality and routing.
  final String key;

  /// Short display label shown below the icon.
  final String label;

  /// Tab icon.
  final IconData icon;

  /// Whether this tab is interactive. Disabled tabs are greyed out.
  final bool enabled;

  const MinigameBottomTab({
    required this.key,
    required this.label,
    required this.icon,
    this.enabled = true,
  });

  /// Default tab set. Used by BreathingSessionScreen when no
  /// [MinigameSession.bottomTabs] override is provided.
  ///
  /// Tab index 3 ('settings') hosts the Session Settings panel
  /// (phase timings + cycle count). Previously a placeholder,
  /// now a fully implemented settings page.
  static const List<MinigameBottomTab> defaults = [
    MinigameBottomTab(
        key: 'activity', label: 'Activity', icon: Icons.self_improvement),
    MinigameBottomTab(
        key: 'leaderboard', label: 'Rankings', icon: Icons.emoji_events),
    MinigameBottomTab(
        key: 'skills', label: 'Skills', icon: Icons.bolt),
    MinigameBottomTab(
        key: 'settings', label: 'Settings', icon: Icons.tune),
  ];
}

// ─────────────────────────────────────────────────────────────
// LEADERBOARD ENTRY — One ranked part for the leaderboard tab
// ─────────────────────────────────────────────────────────────

/// A single leaderboard entry: one IFS part (character) and the
/// cumulative time the user has spent in sessions with it.
///
/// Built by the host app before launching a minigame and stored in
/// [MinigameSession.leaderboardEntries] (sorted desc by hangoutSeconds).
class MinigameLeaderboardEntry {
  final MinigameCharacter character;

  /// Total seconds spent with this part across all sessions.
  final int hangoutSeconds;

  /// True when this entry is the part for the current active session.
  final bool isCurrentCharacter;

  const MinigameLeaderboardEntry({
    required this.character,
    required this.hangoutSeconds,
    this.isCurrentCharacter = false,
  });
}

// ─────────────────────────────────────────────────────────────
// RESULT — What a NotSelf minigame returns when it finishes
//
// Privacy guarantee: only the final label (e.g. parts_band) and
// aggregate scores leave the minigame. Raw interaction data stays
// local and is discarded after scoring. The host app reads
// MinigameResult and applies rewards — it never sees the raw session.
// ─────────────────────────────────────────────────────────────

/// The output a NotSelf minigame returns to the host app on completion.
/// The host reads this and applies all rewards and state updates.
///
/// For Parts Mirror and other IFS-grounded minigames, the key output
/// is customData['parts_band'] — the privacy-safe maturity label.
class MinigameResult {
  /// How many IQ (Insight Quoins) the player earned this session
  final int iqEarned;

  /// How many EQ (Experience Quoins) the player earned this session
  final int eqEarned;

  /// Total seconds the player spent in the minigame
  final int durationSeconds;

  /// Whether the session was completed (vs cancelled/quit early)
  final bool completed;

  /// The phase the user was in when they exited.
  /// 'complete'                          — finished naturally.
  /// 'recall'|'embody'|'inquire'|'listen' — quit mid-session.
  /// 'ready'                             — quit before starting.
  /// null                                — minigame doesn't track phases.
  final String? phaseAtExit;

  /// Optional: the last reaction emoji shown (for brain-training display)
  final String? lastReactionEmoji;

  /// Optional: index into reactionPool for brain-training feedback.
  ///
  /// TRAINING CONTRACT:
  ///   - API path (MinigameSession provided): set this to the pool index
  ///     of the last emoji shown. The host app's _applyMinigameResult
  ///     handles the training update.
  ///   - Legacy direct-nav path (no session): the minigame trains
  ///     internally and must leave this null.
  ///   - NEVER set this AND train internally — that causes double-training.
  final int? lastReactionIndex;

  /// Custom key-value data the minigame wants to surface to the host.
  ///
  /// For NotSelf IFS minigames the expected key is:
  ///   'parts_band' → 'exploring' | 'aware' | 'self_led'
  ///
  /// Raw scoring signals MUST NOT be included here — only the final
  /// label. This field is the single privacy-safe output channel.
  final Map<String, dynamic>? customData;

  const MinigameResult({
    this.iqEarned = 0,
    this.eqEarned = 0,
    this.durationSeconds = 0,
    this.completed = false,
    this.phaseAtExit,
    this.lastReactionEmoji,
    this.lastReactionIndex,
    this.customData,
  });
}

// ─────────────────────────────────────────────────────────────
// MINIGAME REGISTRY — How the host discovers available minigames
// ─────────────────────────────────────────────────────────────

/// Metadata for a NotSelf minigame that appears in the part action sheet.
/// Register one of these per minigame via [MinigameRegistry.register]
/// during host app initialisation.
class MinigameEntry {
  /// Unique key for this minigame (e.g. 'parts_mirror', 'breathing')
  final String key;

  /// Large display label shown in the action sheet (e.g. "Parts Mirror")
  final String title;

  /// Smaller subtitle (e.g. "explore your inner family")
  final String subtitle;

  /// Reward preview text (e.g. "+10 IQ")
  final String rewardLabel;

  /// Icon to display in the action sheet
  final IconData icon;

  /// Difficulty tag shown as a badge (null = hide)
  final String? difficulty;

  /// Color override (null = use the part's element color)
  final Color? color;

  /// Builder that creates the minigame screen widget.
  /// Receives the session on launch; must return a Widget (full screen).
  /// The screen calls Navigator.pop(context, MinigameResult) when done.
  final Widget Function(MinigameSession session) builder;

  /// Whether this minigame is currently available
  final bool enabled;

  /// Sort order in the action sheet (lower = higher)
  final int sortOrder;

  const MinigameEntry({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.rewardLabel,
    required this.icon,
    this.difficulty,
    this.color,
    required this.builder,
    this.enabled = true,
    this.sortOrder = 100,
  });
}

/// Central registry of all available NotSelf minigames.
/// The host app populates this at startup; the part action sheet reads it.
class MinigameRegistry {
  static final List<MinigameEntry> _entries = [];

  /// Register a new minigame. Call this during host app initialisation.
  static void register(MinigameEntry entry) {
    _entries.removeWhere((e) => e.key == entry.key);
    _entries.add(entry);
    _entries.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  /// Get all registered minigames (optionally filtered to enabled only)
  static List<MinigameEntry> all({bool enabledOnly = true}) {
    if (enabledOnly) return _entries.where((e) => e.enabled).toList();
    return List.unmodifiable(_entries);
  }

  /// Get a specific minigame by its unique key
  static MinigameEntry? get(String key) {
    try {
      return _entries.firstWhere((e) => e.key == key);
    } catch (_) {
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// THEME CONSTANTS — NotSelf visual language for all minigames
// ─────────────────────────────────────────────────────────────

/// Visual constants minigames must use to match the NotSelf aesthetic.
/// Minigames MUST NOT import app_theme.dart — use this instead.
/// Consistent visuals across minigames signal one coherent product
/// to judges and users alike.
class MinigameTheme {
  // Backgrounds
  static const Color bgDeep = Color(0xFF0A0A14);
  static const Color bgCard = Color(0xFF1A1A2E);
  static const Color bgElevated = Color(0xFF16162A);
  static const Color bgSurface = Color(0xFF12121E);

  // Text
  static const Color textPrimary = Color(0xFFE8E8F0);
  static const Color textMuted = Color(0xFF8888AA);

  // Accent colors (mapped from element)
  static const Color accentFire = Color(0xFFFF6B35);
  static const Color accentWater = Color(0xFF4FC3F7);
  static const Color accentEarth = Color(0xFF81C784);
  static const Color accentAir = Color(0xFFCE93D8);
  static const Color accentVoid = Color(0xFFFFD54F);
  static const Color accentGold = Color(0xFFFFD700);

  /// Get element color from element string
  static Color elementColor(String element) {
    switch (element.toLowerCase()) {
      case 'fire': return accentFire;
      case 'water': return accentWater;
      case 'earth': return accentEarth;
      case 'air': return accentAir;
      case 'void': return accentVoid;
      default: return accentWater;
    }
  }

  // Typography helpers
  static TextStyle heading(Color color) => TextStyle(
    color: color,
    fontSize: 17,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
  );

  static TextStyle body(Color color, {double opacity = 1.0}) => TextStyle(
    color: color.withOpacity(opacity),
    fontSize: 13,
  );

  static TextStyle label(Color color) => TextStyle(
    color: color.withOpacity(0.7),
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.5,
  );

  // Common decorations
  static BoxDecoration cardDecoration(Color color) => BoxDecoration(
    color: bgCard.withOpacity(0.8),
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: color.withOpacity(0.2)),
  );

  static BoxDecoration glowDecoration(Color color, {double opacity = 0.3}) =>
      BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [
          color.withOpacity(opacity),
          color.withOpacity(opacity * 0.3),
          Colors.transparent,
        ]),
      );
}

// ─────────────────────────────────────────────────────────────
// MINIGAME BODY MAP — Self-contained somatic silhouette widget
//
// NotSelf minigames use this to display body regions without
// importing card_body_map.dart or any host-app widget. Supports
// the Body Compass minigame and any other somatic awareness game.
// ─────────────────────────────────────────────────────────────

/// Renders a simplified human silhouette with highlighted body-region
/// dots and optional outward direction arrows — used in NotSelf's
/// somatic awareness minigames (e.g. Body Compass).
///
/// Pass [character.bodyRegions] directly — pre-resolved by the host
/// app before launching so the minigame stays stateless and clean.
///
/// Example usage inside a minigame:
/// ```dart
/// MinigameBodyMap(
///   regions: session.character.bodyRegions,
///   accentColor: session.character.elementColor,
///   width: 56,
///   height: 92,
///   showArrows: true,
/// )
/// ```
class MinigameBodyMap extends StatelessWidget {
  final List<MinigameBodyRegion> regions;
  final Color accentColor;
  final double width;
  final double height;

  /// Draw outward direction arrows when angle is available.
  final bool showArrows;

  const MinigameBodyMap({
    super.key,
    required this.regions,
    required this.accentColor,
    this.width = 44,
    this.height = 72,
    this.showArrows = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _MinigameBodyPainter(
          accentColor: accentColor,
          regions: regions,
          showArrows: showArrows,
        ),
      ),
    );
  }
}

class _MinigameBodyPainter extends CustomPainter {
  final Color accentColor;
  final List<MinigameBodyRegion> regions;
  final bool showArrows;

  _MinigameBodyPainter({
    required this.accentColor,
    required this.regions,
    required this.showArrows,
  });

  Offset _px(double nx, double ny, Size s) =>
      Offset(nx * s.width, ny * s.height);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = Colors.white.withOpacity(0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.025
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final fill = Paint()
      ..color = Colors.white.withOpacity(0.04)
      ..style = PaintingStyle.fill;

    _silhouette(canvas, size, stroke, fill);
    _highlights(canvas, size);
    if (showArrows) _arrows(canvas, size);
  }

  void _silhouette(Canvas canvas, Size size, Paint stroke, Paint fill) {
    final w = size.width;
    final h = size.height;
    // Head
    final hc = _px(0.50, 0.085, size);
    canvas.drawCircle(hc, w * 0.145, fill);
    canvas.drawCircle(hc, w * 0.145, stroke);
    // Neck
    final neck = Path()
      ..moveTo(w * 0.43, h * 0.165)
      ..lineTo(w * 0.37, h * 0.225)
      ..lineTo(w * 0.63, h * 0.225)
      ..lineTo(w * 0.57, h * 0.165)
      ..close();
    canvas.drawPath(neck, fill);
    canvas.drawPath(neck, stroke);
    // Torso
    final torso = RRect.fromLTRBR(w * 0.27, h * 0.225, w * 0.73, h * 0.565,
        Radius.circular(w * 0.06));
    canvas.drawRRect(torso, fill);
    canvas.drawRRect(torso, stroke);
    // Arms
    for (final left in [true, false]) {
      final xs = left ? -1.0 : 1.0;
      final cx = 0.50 + xs * 0.23;
      final arm = Path()
        ..moveTo(w * (cx - 0.04), h * 0.225)
        ..cubicTo(
            w * (0.50 + xs * 0.34), h * 0.29,
            w * (0.50 + xs * 0.37), h * 0.40,
            w * (0.50 + xs * 0.38), h * 0.56)
        ..lineTo(w * (0.50 + xs * 0.32), h * 0.57)
        ..cubicTo(
            w * (0.50 + xs * 0.30), h * 0.41,
            w * (0.50 + xs * 0.27), h * 0.30,
            w * (cx + 0.04), h * 0.225)
        ..close();
      canvas.drawPath(arm, fill);
      canvas.drawPath(arm, stroke);
    }
    // Legs
    for (final x in [0.33, 0.54]) {
      final leg = RRect.fromLTRBR(w * x, h * 0.555, w * (x + 0.13),
          h * 0.985, Radius.circular(w * 0.05));
      canvas.drawRRect(leg, fill);
      canvas.drawRRect(leg, stroke);
    }
  }

  void _highlights(Canvas canvas, Size size) {
    for (final region in regions) {
      final c = _px(region.nx, region.ny, size);
      final r = size.width * 0.085;
      canvas.drawCircle(
          c,
          r * 1.9,
          Paint()
            ..color = accentColor.withOpacity(0.10)
            ..style = PaintingStyle.fill);
      canvas.drawCircle(
          c,
          r * 1.3,
          Paint()
            ..color = accentColor.withOpacity(0.22)
            ..style = PaintingStyle.fill);
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..color = accentColor.withOpacity(0.85)
            ..style = PaintingStyle.fill);
      canvas.drawCircle(
          Offset(c.dx - r * 0.25, c.dy - r * 0.25),
          r * 0.28,
          Paint()
            ..color = Colors.white.withOpacity(0.55)
            ..style = PaintingStyle.fill);
    }
  }

  void _arrows(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = accentColor.withOpacity(0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.026
      ..strokeCap = StrokeCap.round;

    for (final region in regions) {
      final angle = region.angleRadians;
      if (angle == null) continue;
      _drawArrowAt(canvas, size, Offset(region.nx, region.ny), angle, paint);
    }
  }

  void _drawArrowAt(
      Canvas canvas, Size size, Offset pos, double angle, Paint paint) {
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    final dotR = size.width * 0.085;
    final shaftLen = size.width * 0.13;
    final headLen = size.width * 0.08;
    const headAng = 0.50;

    final c = _px(pos.dx, pos.dy, size);
    final start = Offset(c.dx + dx * dotR * 1.5, c.dy + dy * dotR * 1.5);
    final tip = Offset(start.dx + dx * shaftLen, start.dy + dy * shaftLen);
    canvas.drawLine(start, tip, paint);

    final back = angle + math.pi;
    canvas.drawLine(
        tip,
        Offset(tip.dx + math.cos(back - headAng) * headLen,
            tip.dy + math.sin(back - headAng) * headLen),
        paint);
    canvas.drawLine(
        tip,
        Offset(tip.dx + math.cos(back + headAng) * headLen,
            tip.dy + math.sin(back + headAng) * headLen),
        paint);
  }

  @override
  bool shouldRepaint(_MinigameBodyPainter o) =>
      o.accentColor != accentColor ||
      o.regions != regions ||
      o.showArrows != showArrows;
}


/// Abstract interface for minigame-specific storage.
/// Each minigame can implement its own storage table behind this.
/// The host app provides a concrete implementation (e.g. SQLite).
///
/// Privacy note: minigames should store only aggregate/derived data
/// here — never raw session responses. The parts_band label is the
/// appropriate level of granularity to persist.
abstract class MinigameStorage {
  /// Get a value by key for this minigame
  Future<String?> getValue(String minigameKey, String dataKey);

  /// Set a value by key for this minigame
  Future<void> setValue(String minigameKey, String dataKey, String value);

  /// Delete a value
  Future<void> deleteValue(String minigameKey, String dataKey);

  /// Get all key-value pairs for this minigame
  Future<Map<String, String>> getAll(String minigameKey);
}
