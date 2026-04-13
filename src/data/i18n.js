export const i18n = {
  en: {
    eyebrow: "developer · playground",
    wish: "I wish your happiness. ♡",
    nyaice: ":3 have a nya-ice day!  mㅡㅈㅡm",
    projects: "projects",
    connect: "connect",
    credits: "credits",
    thanks: "Thank you for reading!",
    milktea: "buy me a milk tea",
    madeBy: "@nyanrus",
  },
  ja: {
    eyebrow: "開発者の遊び場",
    wish: "あなたが幸せでありますように！♡",
    nyaice: ":3 素敵な一日を！  mㅡㅈㅡm",
    projects: "プロジェクト",
    connect: "リンク",
    credits: "クレジット",
    thanks: "読んでいただきありがとうございます！",
    milktea: "Buy me a coffee",
    madeBy: "@nyanrus",
  },
"ja-x-morioka": {
    eyebrow: "開発者のあそびばみたいな",
    wish: "幸せになってほしいんだべ！♡",
    nyaice: ":3 いい一日になってけろ！  mㅡㅈㅡm",
    projects: "プロジェクト",
    connect: "リンク",
    thanks: "読んでくれてありがとうがんす！",
    milktea: "ミルクティ奢ってけろ〜",
    madeBy: "@nyanrus",
  },
  "ja-x-kansai": {
    eyebrow: "開発者のあそびばやで",
    wish: "めっちゃ幸せになったれ！♡",
    nyaice: ":3 ええ感じの日になるとええな！  mㅡㅈㅡm",
    projects: "プロジェクト",
    connect: "リンク",
    thanks: "読んでくれてありがとうやで、おおきに！",
    milktea: "ミルクティおごってや〜",
    madeBy: "@nyanrus",
  },
  "ja-x-okayama": {
    eyebrow: "開発者のあそびばみたいな",
    wish: "まじで幸せになってほしいんよ！♡",
    nyaice: ":3 ぼっけーいい感じの一日を！  mㅡㅈㅡm",
    projects: "プロジェクト",
    connect: "リンク",
    thanks: "読んでくれてありがとうなんよ！",
    milktea: "ミルクティ奢ってくれんー？",
    madeBy: "@nyanrus",
  },
  "ja-x-oita": {
    eyebrow: "開発者のあそびば",
    wish: "あんたが幸せになってほしいなぁ！♡",
    nyaice: ":3 ええ一日を！  mㅡㅈㅡm",
    projects: "プロジェクト",
    connect: "リンク",
    thanks: "読んでくれてありがとうなぁ！",
    milktea: "ミルクティこうちくりー",
    madeBy: "@nyanrus",
  },
  ko: {
    eyebrow: "개발자의 놀이터",
    wish: "당신이 행복해지길! ♡",
    nyaice: ":3 냥이스한 하루 되세요!  mㅡㅈㅡm",
    projects: "프로젝트",
    connect: "링크",
    credits: "크레딧",
    thanks: "읽어주셔서 감사합니다!",
    milktea: "밀크티 사줘요",
    madeBy: "@nyanrus",
  },
  "ko-x-busan": {
    eyebrow: "개발자 놀이터다!",
    wish: "행복해져라! ♡",
    nyaice: ":3 냥이스한 하루 되이소!  mㅡㅈㅡm",
    projects: "프로젝트",
    connect: "링크",
    thanks: "읽어줘서 고맙습니더!",
    milktea: "밀크티 사주이소",
    madeBy: "@nyanrus",
  },
  "ko-x-chungcheong": {
    eyebrow: "개발자 놀이터유",
    wish: "행복하셨음 쓰겄어유~ ♡",
    nyaice: ":3 냥이스한 하루 되셔유!  mㅡㅈㅡm",
    projects: "프로젝트",
    connect: "링크",
    thanks: "읽어주셔서 감사혀유!",
    milktea: "밀크티 사줘유",
    madeBy: "@nyanrus",
  },
  "ko-x-andong": {
    eyebrow: "개발자 놀이터라카이",
    wish: "행복해지소! ♡",
    nyaice: ":3 냥이스한 하루 되이소!  mㅡㅈㅡm",
    projects: "프로젝트",
    connect: "링크",
    thanks: "읽어줘서 고맙소!",
    milktea: "밀크티 사주소",
    madeBy: "@nyanrus",
  },
};

export const LANGS = [
  { key: "en",                        label: "en" },
  { key: "ja",                        label: "ja" },
  { key: "ja-x-morioka",               label: "盛岡" },
  { key: "ja-x-kansai",               label: "関西" },
  { key: "ja-x-okayama",              label: "岡山" },
  { key: "ja-x-oita",                 label: "大分" },
  { key: "ko",                        label: "ko" },
  { key: "ko-x-busan",                  label: "부산" },
  { key: "ko-x-chungcheong",          label: "충청" },
  { key: "ko-x-andong",               label: "안동" },
];

/** Field-level string lookup with fallback: "ja-x-oita" → "ja" → "en" */
export function t(obj, lang) {
  return obj[lang] ?? obj[lang.split("-")[0]] ?? obj["en"];
}

/** Locale object for a given lang, merging primary → dialect so missing fields fall back */
export function locale(lang) {
  const primary = i18n[lang.split("-")[0]] ?? {};
  const dialect = i18n[lang] ?? {};
  return { ...primary, ...dialect };
}
