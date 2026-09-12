// commitlint 配置：Conventional Commits + 中文提交规范
// 完整规范见 AGENTS.md「Conventions」提交消息条目
// 校验规则：
//   - 必须包含 scope（scope-empty）
//   - subject（描述）必须含中文字符（subject-chinese，自定义）
//   - 提交信息禁止破折号 ——/—/--（no-dash，自定义），详情写 body
//   - body 统一使用无序号列表（body-list，自定义）
//   - 其余格式规则继承 @commitlint/config-conventional

module.exports = {
  extends: ['@commitlint/config-conventional'],
  plugins: [
    {
      rules: {
        // 描述必须包含中文字符；技术名词/文件名可保留英文，但描述整体须用中文撰写
        'subject-chinese': (parsed) => {
          const subject = parsed.subject ?? '';
          return [
            /\p{Script=Han}/u.test(subject),
            'subject 必须包含中文字符（描述使用中文撰写，技术名词可保留英文）',
          ];
        },
        // 禁止破折号：旧格式用 —— 在同一行衔接摘要与详情，导致标题过长、层级混乱；详情应写入 body
        'no-dash': (parsed) => {
          const text = [parsed.header, parsed.body, parsed.footer].filter(Boolean).join('\n');
          return [
            !/(——|—|--)/.test(text),
            '提交信息禁止使用破折号（——/—/--），详情请换行写入 body',
          ];
        },
        // body 统一使用无序号列表：每个非空行以 "- " 开头（单连字符不在 no-dash 检查范围）
        'body-list': (parsed) => {
          const body = parsed.body ?? '';
          if (!body.trim()) return [true];
          const bad = body.split('\n').filter((l) => l.trim() !== '' && !l.startsWith('- '));
          return [
            bad.length === 0,
            'body 必须使用无序号列表：每个非空行以 "- " 开头',
          ];
        },
      },
    },
  ],
  rules: {
    'scope-empty': [2, 'never'], // scope 必填
    'subject-case': [0], // 中文描述不适用大小写规则
    'header-max-length': [2, 'always', 100],
    'body-leading-blank': [2, 'always'], // 详情写 body 时须空行分隔，否则并入标题
    'body-max-line-length': [0], // 中文正文不按英文行长限制
    'footer-max-line-length': [0],
    // 本项目规范不使用 footer（body 统一 "- " 列表）；中文 body 中的 # 引用（如 SIGSEGV 地址 #912）
    // 会被 conventional-commits-parser 误判为 issue 引用划入 footer，故关闭该默认提示
    'footer-leading-blank': [0],
    // scope 列表（新增 scope 需同步本清单与 AGENTS.md）；NextDOS 架构：
    // view=ArkTS UI，model=ArkTS 非 UI 层，engine=C++ 原生层与 DOSBox 引擎，
    // build=工程配置/权限/依赖，docs=文档，resources=图标等应用资源
    'scope-enum': [
      1,
      'always',
      [
        'view', 'model', 'engine', 'build', 'docs', 'resources',
      ],
    ],
    'subject-chinese': [2, 'always'],
    'no-dash': [2, 'always'],
    'body-list': [2, 'always'],
  },
};
