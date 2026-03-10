# 技术设计文档 (TDD) - 智驾影音 V2.0 (Smart Drive Video)

| 字段 | 值 |
| --- | --- |
| **技术负责人** | @TechLead |
| **产品经理** | @ProductManager |
| **团队成员** | Frontend Dev, Mobile Dev |
| **关联文档** | [V2 PRD](./PRD.md), [V2 DESIGN](./DESIGN.md) |
| **状态** | 🟢 进行中 (In Progress) |
| **创建日期** | 2026-03-10 |
| **版本** | 2.0.0 |

---

## 1. 背景 (Context)

智驾影音 V1.0 验证了基础的行车记录仪文件解析与多轨同步能力，但因交互复杂（“程序员思维”）导致用户使用门槛高。V2.0 旨在通过**场景化模板**和**逻辑时间轴**实现“体验降维”，让普通车主能快速生成高质量行车视频。

**核心变更**：
*   **交互层**：从“文件管理器”转向“场景化创作工具”（首页网格、模板抽屉）。
*   **逻辑层**：引入“虚拟时间轴”屏蔽底层物理分片，支持跨文件无缝剪辑。
*   **渲染层**：增强 FFmpeg 渲染管线，支持画中画 (PiP)、动态遮罩 (Masking) 和多流预加载。

---

## 2. 问题定义与动机 (Problem Statement & Motivation)

### 2.1 我们解决的问题
1.  **物理碎片化**：行车记录仪每分钟生成一个文件，用户想剪辑跨越分界点的 2 分钟视频极其困难。
2.  **排版专业门槛**：多路视频（前后左右）的拼接需要专业知识，用户不知道如何布局才美观且具备证据效力。
3.  **隐私焦虑**：分享视频时担心泄露车速、VIN 码等敏感信息。

### 2.2 为什么现在做？
V1 积累的反馈表明，工具属性太强导致用户留存低。V2 通过“一键成片”的模板化体验，有望通过社交分享带来自然增长。

---

## 3. 范围 (Scope)

### ✅ 包含 (In Scope - V2.0)
*   **首页重构**：双列网格布局，首帧沉浸式预览，支持多选合并。
*   **逻辑时间轴**：将多个 1 分钟物理文件映射为一条连续的虚拟时间轴。
*   **无缝预览**：合并后的视频流在播放器中无缝过渡（预加载技术）。
*   **场景化模板**：内置 4 款排版模板（防追尾、防加塞、防开门杀、旅拍）。
*   **动态隐私遮罩**：基于绝对坐标的实时渲染遮罩（车速/VIN）。
*   **高级导出**：支持 4K 导出，可选静音、倍速、水印。

### ❌ 不包含 (Out of Scope)
*   云端同步与备份（维持本地化）。
*   AI 智能识别违章/事故（依赖人工选区）。
*   自定义模板编辑器（用户不可修改模板布局）。

---

## 4. 技术方案 (Technical Solution)

### 4.1 架构概览 (Architecture Overview)

V2.0 延续 V1 的 MVVM 架构，但在 Model 层引入了中间抽象层 `VirtualTimeline`。

```mermaid
graph TD
    UI[UI Layer (ArkUI/Flutter)] -->|Bind| VM[ViewModel]
    VM -->|Manage| TL[Virtual Timeline Engine]
    TL -->|Map| FS[File System Repository]
    TL -->|Render| Player[Multi-Track Player]
    TL -->|Export| FF[FFmpeg Engine]
```

### 4.2 核心模块设计

#### 4.2.1 虚拟时间轴引擎 (Virtual Timeline Engine)
*   **职责**：屏蔽物理文件差异，对外暴露统一的 `00:00 ~ XX:XX` 逻辑坐标。
*   **数据结构**：
    ```typescript
    interface VirtualClip {
      id: string;
      sourceFiles: VideoSegment[]; // 物理文件列表 [A.mp4, B.mp4]
      totalDuration: number;       // A.duration + B.duration
      // 逻辑时间 -> 物理文件映射
      mapTime(logicTime: number): { file: VideoSegment, offset: number };
    }
    ```
*   **映射算法**：
    *   输入逻辑时间 `T`。
    *   遍历 `sourceFiles`，累加时长直到 `sum > T`。
    *   返回目标文件及 `offset = T - (sum - current.duration)`。

#### 4.2.2 无缝播放器 (Seamless Player)
*   **挑战**：在播放 File A 结束切换到 File B 时，通常会有 100-500ms 的黑屏或缓冲。
*   **解决方案：双播放器轮转 (Dual-Player Swap)**
    *   创建两个播放器实例 `Player A` (Active) 和 `Player B` (Standby)。
    *   当 `Player A` 播放到剩余 5 秒时，`Player B` 预加载下一个文件并 `seek(0)` 暂停。
    *   `Player A` 结束瞬间，`Player B` 启动，`Player A` 隐藏并加载下下个文件。
    *   UI 层覆盖一层透明 View 拦截手势，统一分发给 Active Player。

#### 4.2.3 场景化渲染管线 (Scenario Render Pipeline)
*   **模板定义 (JSON)**：
    ```json
    {
      "id": "template_pip",
      "layout": [
        { "track": "front", "z": 0, "rect": [0, 0, 1, 1] }, // 全屏
        { "track": "rear", "z": 1, "rect": [0.7, 0.05, 0.25, 0.25], "radius": 12 } // 右上角小窗
      ],
      "mask": [
        { "type": "blur", "rect": [0.05, 0.9, 0.2, 0.08] } // 左下角车速遮挡
      ]
    }
    ```
*   **预览实现**：
    *   UI 层使用绝对定位布局 (`Stack` / `AbsoluteLayout`) 模拟模板效果。
    *   遮罩层使用 CSS Blur / ArkUI BlurEffect 实时覆盖视频组件。
*   **导出实现**：
    *   将 JSON 模板转换为 FFmpeg `filter_complex` 命令。
    *   例 (PiP)：`[0:v][1:v] overlay=W*0.7:H*0.05`。
    *   例 (Mask)：`delogo=x=W*0.05:y=H*0.9:w=W*0.2:h=H*0.08`。

### 4.3 首页网格与多选 (Home Grid)
*   **性能优化**：
    *   使用 `LazyForEach` (ArkUI) 或 `RecyclerView` (Android) 加载网格。
    *   **首帧缓存**：扫描视频时，使用 FFmpeg 快速提取第 0 帧并缓存为 JPG。
    *   **异步加载**：列表滚动时优先显示占位图，停止滚动后加载真实缩略图。

---

## 5. 风险 (Risks)

| 风险 | 影响 | 概率 | 缓解措施 |
| --- | --- | --- | --- |
| **无缝播放卡顿** | 高 | 中 | 在低端机上预加载可能抢占解码资源。策略：低端机增加 200ms 转场黑屏过渡，保证不崩溃。 |
| **FFmpeg 复杂滤镜发热** | 中 | 高 | 限制导出分辨率（4K源 -> 1080P导出），或提示用户连接电源。使用硬编解码。 |
| **音频同步问题** | 中 | 低 | 跨文件合并时，若物理文件有丢帧，可能导致音画不同步。策略：强制重采样音频。 |

---

## 6. 实施计划 (Implementation Plan)

| 阶段 | 任务 | 描述 | 依赖 | 预估 |
| --- | --- | --- | --- | --- |
| **Phase 1: Core** | 虚拟时间轴 | 实现 VirtualClip 及映射算法 | - | 3d |
| | 双播放器 | 封装 SeamlessPlayer 组件 | 虚拟时间轴 | 5d |
| **Phase 2: UI** | 首页网格 | 双列布局、多选状态、底部浮层 | - | 4d |
| | 剪辑台重构 | 四层布局实现 (Preview, Control, Timeline, Drawer) | 双播放器 | 5d |
| **Phase 3: Render** | 模板引擎 | 实现 JSON -> UI 布局的解析器 | - | 3d |
| | FFmpeg 转换 | 实现 JSON -> filter_complex 的转换器 | 模板引擎 | 4d |
| **Phase 4: Polish** | 隐私遮罩 | UI 交互与 FFmpeg delogo 对接 | - | 2d |
| | 性能调优 | 列表滑动流畅度、导出速度优化 | - | 3d |

---

## 7. 测试策略 (Testing Strategy)

### 7.1 核心测试点
*   **合并逻辑**：选取 5 个 1 分钟视频合并，验证总时长是否为 5:00，且过渡处无跳帧。
*   **打码精度**：在不同分辨率（2K/4K）视频源下，遮罩位置是否准确覆盖车速信息。
*   **内存稳定性**：在双播放器轮转机制下，连续播放 30 分钟，监控内存是否有泄漏。

### 7.2 兼容性测试
*   **屏幕适配**：验证刘海屏、挖孔屏下的安全区适配（首页 Grid、剪辑台 Toolbar）。
*   **解码兼容**：覆盖 H.264 / H.265 编码格式的视频源。

---

## 8. 安全与隐私 (Security)

*   **本地化原则**：再次重申，所有 AI 识别（如有）、打码渲染、视频合成均在**手机本地**完成，绝不上传云端。
*   **权限管理**：相册权限仅在导入和导出时刻调用，App 处于后台时释放文件句柄。
