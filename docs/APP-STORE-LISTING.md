# App Store 上架资料

复制到 App Store Connect → VocabLoop 对应位置即可。字数限制已核对。

---

## 0. 上架前必须先做的事（不做内购无法使用）

1. **付费 App 协议**：App Store Connect → 商务（Business）→ 协议，签署 **Paid Applications Agreement**，并填好**银行账户**和**税务信息**。
   没签之前，App 里的 Plus 价格加载不出来，TestFlight 里也买不了。
2. **创建内购项目**（见第 4 节）。
3. **网站**：部署在自己的服务器 `https://mle.doge6.com/`（`.github/workflows/deploy-site.yml`，`site/` 有改动时自动通过 SSH 上传并配置 nginx + HTTPS）。发版时 App 默认使用这个网址；需要换地址时在 Variables 里设置 `WEBSITE_URL` 覆盖。
4. **Google 登录发布**：Google Cloud → Google Auth Platform → 品牌塑造，填：
   - 应用首页：`https://mle.doge6.com/`
   - 隐私权政策：`https://mle.doge6.com/privacy.html`
   - 服务条款：`https://mle.doge6.com/terms.html`
   - 已获授权的网域：`doge6.com`

   然后到“目标对象”点“发布应用”。

---

## 1. App 信息（App Information）

| 字段 | 内容 |
|---|---|
| 名称 Name（≤30） | VocabLoop |
| 主要类别 | 教育 Education |
| 次要类别 | 参考 Reference |
| 内容版权 | © 2026 你的法定姓名（需与开发者账号一致） |
| 隐私政策网址 | `https://mle.doge6.com/privacy.html` |
| 年龄分级 | **4+**（问卷全部选“无”） |
| 儿童类别（Made for Kids） | **不勾选**。勾选后，App 内购和外部链接都要加家长验证，Google 登录也不允许。“适合孩子”写在描述里即可。 |

## 2. 版本信息 — 简体中文

**副标题 Subtitle（≤30）**

```
打开就背，会记住的单词卡
```

**宣传文本 Promotional Text（≤170，可随时修改无需审核）**

```
打开就是单词卡，想背多少背多少。FSRS 记忆算法在你快忘的时候提醒复习。无广告、不追踪、离线可用，孩子和大人都爱用。
```

**描述 Description**

```
VocabLoop 是一款打开就能背的单词卡。

没有菜单，没有关卡，打开 App 就是一张单词卡。想背多少背多少，停了就停了。

【会记住，是因为复习得刚刚好】
VocabLoop 使用 FSRS 记忆算法，为每个单词计算你大概什么时候会忘，并在那之前安排复习。背得越熟，间隔越长；容易忘的词会更常出现。

【轻松开始】
• 打开就学，常用词自动安排
• 每日目标可设可不设，达成时有小小的庆祝 🎉
• 发音、例句、填空卡
• 可爱的蜡笔风设计，还有陪你背单词的小伙伴 Mochi

【安心】
• 无广告、无追踪、不收集任何个人数据
• 全部离线可用，数据只保存在你的设备上
• 可以不注册直接使用；也支持邮箱、Apple、Google 登录

【VocabLoop Plus · 一次买断】
背单词永久免费。Plus 为一次性购买（非订阅），解锁：
• English Core B1–B2、C1 进阶词库，以及今后所有新词库
• 根据你的复习记录调节记忆算法

使用条款：https://mle.doge6.com/terms.html
隐私政策：https://mle.doge6.com/privacy.html
```

**关键词 Keywords（≤100 字符，逗号分隔、不加空格）**

```
单词,背单词,英语单词,词汇,记单词,英语学习,单词卡,闪卡,记忆曲线,艾宾浩斯,四级,六级,雅思,托福,小学英语
```

**技术支持网址** `https://mle.doge6.com/support.html`
**营销网址** `https://mle.doge6.com/`

## 3. 版本信息 — English (U.S.)

**Subtitle（≤30）**

```
Word cards that stick
```

**Promotional Text**

```
Open the app and you are on a word. Study as much as you like — the FSRS memory algorithm brings each word back just before you would forget it. No ads, no tracking.
```

**Description**

```
VocabLoop is a flashcard app that opens straight onto a word.

No menus, no levels to pick. Study as much as you like, and stop whenever you want.

REMEMBER MORE, REVIEW LESS
VocabLoop schedules reviews with FSRS, a modern memory algorithm that estimates when you are about to forget each word and brings it back just in time. Words you know well come back less often; tricky ones return sooner.

EASY TO START
• Common words are introduced for you automatically
• An optional daily goal, with a little celebration when you reach it 🎉
• Pronunciation, example sentences and fill-in-the-blank cards
• A friendly crayon look, and Mochi to keep you company

PRIVATE BY DESIGN
• No ads, no tracking, no personal data collected
• Works fully offline; your data stays on your device
• Use it without an account, or sign in with email, Apple or Google

VOCABLOOP PLUS — ONE-TIME PURCHASE
Studying is free forever. Plus is a single purchase, not a subscription, and adds:
• The English Core B1–B2 and C1 packs, plus every future pack
• Memory tuning fitted to your own review history

Terms of Use: https://mle.doge6.com/terms.html
Privacy Policy: https://mle.doge6.com/privacy.html
```

**Keywords**

```
vocabulary,flashcards,english,words,spaced repetition,fsrs,learn english,esl,ielts,toefl,memory,kids
```

## 4. App 内购买项目（In-App Purchase）

App Store Connect → VocabLoop → 功能 → App 内购买项目 → ＋

| 字段 | 内容 |
|---|---|
| 类型 | **非消耗型项目 Non-Consumable** |
| 参考名称 | VocabLoop Plus Lifetime |
| 产品 ID | `com.vocabloop.app.plus.lifetime`（**必须一字不差**，App 里写死了这个 ID） |
| 价格 | ¥198（美区对应约 $29.99） |
| 家人共享 | 建议开启 |
| 显示名称（中文） | VocabLoop Plus 终身版 |
| 描述（中文，≤45） | 一次买断：解锁全部进阶词库与记忆调节 |
| 显示名称（English） | VocabLoop Plus Lifetime |
| 描述（English，≤45） | Unlock every word pack and memory tuning |
| 审核截图 | App 里“设置 → VocabLoop Plus”页面的截图 |
| 审核备注 | Plus unlocks the B1–B2 and C1 word packs and memory tuning. Open Settings ▸ VocabLoop Plus. |

**第一个内购必须和一个新 App 版本一起提交审核**：在版本页面的“App 内购买项目和订阅”区域把它加上。

## 5. App 隐私（App Privacy）

- 问卷选：**“否，我们不从此 App 中收集数据”** → 结果为 **Data Not Collected（未收集数据）**。
- 依据：
  - 账户、名字、邮箱、学习记录都只存在设备上，不传给开发者。Apple 对“收集”的定义是“传出设备、开发者或其合作方可访问”，这些都不算。
  - Apple/Google 登录由用户主动发起，信息只存本机。
  - 没有统计、广告或崩溃分析 SDK。

## 6. 审核信息（App Review Information）

- **登录**：不需要演示账号。App 可在游客模式下使用全部功能；邮箱注册在本机完成，不需要验证邮件。
- **备注（Notes）**：

```
VocabLoop works fully without an account (guest mode). Email sign-up is local to the device; Sign in with Apple and Sign in with Google are optional.
The in-app purchase "VocabLoop Plus Lifetime" (non-consumable) is in Settings > VocabLoop Plus, with a Restore Purchase button.
No data is collected; everything is stored on the device.
```

## 7. 截图

必需尺寸：6.9 英寸（1320×2868 或 1290×2796）。建议 5 张：

1. 单词卡正面：“打开就是单词卡”
2. 翻面后的释义和例句：“发音、例句、填空卡”
3. 达成每日目标 🎉：“每天一点点”
4. 词库列表：“从基础到进阶”
5. Plus 页面：“一次买断，永久使用”

## 8. 词库规模

内置英文词库共 **3,301 词**，每个词都有音标、中文释义、例句和中文翻译，约三分之一附用法提示：

| 词库 | 词数 | 免费 / Plus |
|---|---|---|
| English Core · A1–A2 | 1,046 | 免费 |
| English Core · B1–B2 | 1,526 | Plus |
| English Core · C1 | 729 | Plus |

Plus 解锁 2,255 词。描述里可以写“3,000+ 词”。
