# Design System: Smart Drive Video V2 (智驾影音)

**Version:** 2.0
**Theme:** Cinematic / Immersive / Safety-First
**Base:** [V1.0 Design System](../v1/DESIGN.md)

## 1. Design Philosophy (设计哲学)

V2.0 shifts from "Technical Utility" to **"Cinematic Creator"**. The interface should feel less like a file manager and more like a streamlined creative tool.

*   **Immersive (沉浸感)**: The video content is the hero. UI controls recede when not in use.
*   **Scenario-First (场景优先)**: Replace technical terms ("Tracks", "Files") with visual scenarios ("Rear-End", "Vlog").
*   **Trustworthy (安全信赖)**: Privacy features are prominent and provide clear visual feedback (e.g., masking zones).

## 2. Home Library System (首页交互规范)

### Layout (布局)
*   **Grid**: Dual-column (`grid-cols-2`), Gap `12px`.
*   **Safe Area**: Top padding for status bar, Bottom padding for Home Indicator. Fully compatible with iPhone notch and Android punch-hole.

### Trip Card (行程卡片)
*   **Aspect Ratio**: 4:3 (Standard video thumb).
*   **Background**: Full-bleed Front Camera Frame (首帧画面).
*   **Overlay**: `bg-gradient-to-t from-black/90 to-transparent` (Bottom 40%) for text readability.
*   **Typography**:
    *   Time (e.g., "22:17"): Bold, White, Bottom-Left.
    *   Duration badge: Top-Right, Glassmorphism (`bg-black/60`).
*   **Interaction**:
    *   **Tap**: Open Editor (Single Clip).
    *   **Select Mode**: Toggle Selection Overlay.

### Selection & Merge (多选合并交互)
*   **Trigger**: "Select" button in Top Bar.
*   **Visual State**:
    *   **Active**: Orange border (`border-2 border-orange-500`) + Checkmark badge overlay.
*   **Bottom Bar (Merge Deck)**:
    *   Position: Fixed Bottom (above Safe Area).
    *   Content: Total Duration summary (e.g., "3 min total") + "Merge & Edit" CTA (Primary Orange).
    *   **Animation**: Slide up from bottom when selection > 0.
*   **Merged Editor Behavior (合并预览态)**:
    *   **Timeline**: Rendered as a single continuous track.
    *   **Seams**: Subtle vertical dashed lines (`border-dashed border-white/20`) indicate physical file boundaries on the timeline track.
    *   **Playback**: Seamless transition across boundaries. No black screen or loading spinner between clips.

## 3. The 4-Layer Layout Structure (四层核心布局)

The V2 Editor adopts a strict top-down hierarchy to guide the user flow naturally.

### Layer 1: The Stage (预览舞台)
*   **Height**: Dynamic (approx 40-50% of screen).
*   **Content**: Real-time rendering of the selected template.
*   **Behavior**:
    *   **Landscape Mode**: Takes up the left 60% of the screen.
    *   **Portrait Mode**: Top docked.
    *   **Visual Feedback**: When "Privacy Mask" is active, red/blurred zones appear immediately on this layer.
    *   **Merge Preview**: Seamless playback across multiple clips with no black screen.

### Layer 2: The Control Deck (快捷控制台)
*   **Height**: Fixed 48px bar immediately below the Stage.
*   **Style**: Glassmorphism (`bg-slate-900/80` backdrop-blur).
*   **Elements**:
    *   **Left**: `[Playback Controls]` (Play/Pause, -15s, +15s).
    *   **Center**: `[Timecode]` (e.g., `00:00 / 03:00` for merged clips).
    *   **Right**: Quick Toggles (`[1X Speed]`, `[Mute]`, `[Watermark]`).

### Layer 3: The Logic Timeline (全景时间轴)
*   **Height**: 80px (Expanded touch area).
*   **Interaction**: **Range Slider** (Double-ended).
*   **Visuals**:
    *   **Background**: Continuous Filmstrip thumbnails (Front Camera).
    *   **Boundaries**: Subtle vertical dashed lines (`border-dashed border-white/20`) indicate physical file split points.
    *   **Handles**: Thick, easy-to-grab handles (`w-6 h-12` rounded pills).
    *   **Active Region**: Bright opacity (100%).
    *   **Inactive Region**: Dimmed opacity (30%) + Overlay.
*   **Feedback**: Haptic feedback when snapping to key events or file boundaries.

### Layer 4: The Template Drawer (场景抽屉)
*   **Height**: 120px (Scrollable horizontal list).
*   **Interaction**: Horizontal Scroll (Snap to center).
*   **Components**: **Bento Cards** (See Component Specs).
*   **Content**:
    *   `[Single View]`
    *   `[Pip (Rear-End)]`
    *   `[Matrix (Safety)]`
    *   `[Split (Blindspot)]`
    *   `[Vlog (Vertical)]`

## 4. Visual Style Updates (视觉升级)

### Color Palette (Refined)
Maintaining the V1 Slate base, but shifting the primary action color to **Cinematic Orange** for V2 to differentiate from the "System Blue".

*   **Primary (Action)**: `#F97316` (Orange-500) - Used for Export button, Timeline selection.
*   **Secondary (Active)**: `#EA580C` (Orange-600).
*   **System Blue**: `#3B82F6` (Blue-500) - Retained for "Information" and "Selection" states.
*   **Privacy Red**: `#EF4444` (Red-500) - Used for Privacy Mask indicators.

### Component Specs

#### Bento Template Card (模板卡片)
*   **Size**: 100x100px.
*   **Background**: Slate-800.
*   **State**:
    *   **Normal**: Border Slate-700.
    *   **Selected**: Border-2 Orange-500, Scale 1.05, Shadow-Orange-Glow.
*   **Content**:
    *   **Icon**: Large central SVG (24px).
    *   **Label**: Small text at bottom (12px).
    *   **Preview**: (Optional) Mini animation on hover.

#### Privacy Toggles (Floating Panel)
*   **Location**: Floating above Layer 4 (Right aligned).
*   **Style**: Pill-shaped badges.
*   **States**:
    *   **Off**: Text Slate-400, Border Slate-700.
    *   **On**: Text Red-100, Background Red-500/20, Border Red-500.

## 4. Interaction Flows

### Selecting a Template
1.  User taps "Vlog" card in Layer 4.
2.  **Layer 1** immediately transitions to 9:16 aspect ratio.
3.  **Layer 1** rearranges video feeds into the 3-stack layout.
4.  **Layer 3** (Timeline) remains continuous, playing audio from the main track.

### Applying Privacy Masks
1.  User toggles `[Hide Speed]` in the floating panel.
2.  **Layer 1** shows a "Blur Box" over the bottom-left speedometer area.
3.  Toast notification: "Speed data will be hidden in export".

## 5. Mockup References
See `docs/v2/mockups/editor_v2.html` for the interactive layout visualization.
