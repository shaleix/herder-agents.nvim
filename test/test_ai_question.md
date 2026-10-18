❓ Q2 - 输入形态与双模式： :AIQuestionDev [file]——*(a)* 双模式：.json 文件 = LLM 响应 fixture（跳过网络，直接走 validate() → 表单，顺带测校验层，非法 fixture 能看到重试/兜底链路）；其他文件（.txt 捕获快照）= 全真管线（capture 换成读文件，read-more/重试/兜底照常，真调 LLM）——正好分别服务「内容展示测试」和「提示词调优」两个用途；无参数 = 用当前 buffer 内容（模式按 buffer 是否 json 判定），方便把捕获粘到 scratch buffer 里反复测。
➡️ 推荐 *(a)*：两种用途各走各的路径，fixture 模式还免费测了 validate。

❓ Q3 - dev 模式的提交行为：`import os`  表单里 ctrl+enter 绝不能把文本发进真实 agent pane。*(a)* 组装文本打到 :messages（utils.info）后正常关窗——看到最终提交产物是什么样；*(b)* 同时 yank 进无名寄存器（可直接粘贴比对）；*(c)* 只关窗不展示。
➡️ 推荐 *(a)*（可加 b，成本一行）：调优时最关心「最终发出去的文本长什么样」，messages 里直接可见。

❓ Q4 - 提示词调优的反馈面： 提取完成后要不要展示原始 LLM 输出？*(a)* 原始 `import os`  JSON 响应全文 + 统计（题数 / read-more 轮数 / 重试次数 / 耗时）打到 :messages——表单照常弹，调优时 :messages 一看便知模型理解对了没；*(b)* 只在提取失败/兜底时给原始响应（成功时信表单）；*(c)* 不加，靠表单自身判断。
➡️ 推荐 *(a)*：调提示词的核心循环就是「看原始输出 → 改 prompt → 重跑」，反馈必须无条件全量。
回复 "Q1a Q2a Q3a" 即锁定（Q2 选 a+b 也行），我随即派单条 fixer lane 实现（纯管线侧：question.lua + init.lua + config 命令槽 + smoke 用例，UI 文件不动）。
