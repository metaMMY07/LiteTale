/// Original user supplied rule, compiled into tests only.
const huanmengSourceJson = r'''[
  {
    "bookSourceComment": "池鱼 2025.05.15\n\n本网站所有的小说都是免费的，目前已经有了PC端和wap端，APP端目前还有点问题需要调试\n\n如果想要查看插图的话可以去网页端，为了避免被刷昂贵的图床流量，所以阅读的书源没有适配插图\n\n更多详情内容，可以关注：www.huanmengacg.com\n\n网站QQ群：907189428",
    "bookSourceGroup": "优质无错",
    "bookSourceName": "幻梦轻小说",
    "bookSourceType": 0,
    "bookSourceUrl": "https://www.huanmengacg.com",
    "customOrder": 3,
    "enabled": true,
    "enabledCookieJar": true,
    "enabledExplore": true,
    "header": "@js: \nJSON.stringify({\n  \"User-Agent\": \"Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36\"\n})",
    "lastUpdateTime": 1750730954208,
    "respondTime": 180000,
    "ruleBookInfo": {
      "author": ".book-metas.0@text##作者：",
      "coverUrl": "dt@img@src",
      "intro": ".book-summary@text",
      "kind": ".book-metas.1@text&&.book-metas.2@text&&.book-metas.3@text##(?:分类|状态|更新)：| [\\d：:]+\n<js>result.replace(/ /,\",\")</js>",
      "name": ".book-title@text",
      "tocUrl": "text.章节列表@href"
    },
    "ruleContent": {
      "content": "#BookText@p@text\n<js>\nresult.replace(/(<img src=\"[^\"]+\")[^>]+>/g,\"$1>\")\n</js>\n##本文来自 幻梦轻小说|最新最全的日本动漫轻小说 幻梦轻小说|更多轻小说与TXT下载，尽在幻梦轻小说网（www.huanmengacg.com）|\\(http://www.huanmengacg.com\\)|",
      "imageStyle": "FULL",
      "nextContentUrl": "text.下一页@href"
    },
    "ruleExplore": {},
    "ruleSearch": {
      "author": ".book-module@text##··.*",
      "bookList": ".boxbd@.common-list",
      "bookUrl": "a@href",
      "checkKeyWord": "--https://www.huanmengacg.com/index.php/book_read_794_763.html",
      "coverUrl": "img@data-original",
      "intro": ".book-profile@text",
      "kind": ".book-module@text##.*··",
      "name": "dt@text"
    },
    "ruleToc": {
      "chapterList": "#chapterlist li a",
      "chapterName": "text",
      "chapterUrl": "href",
      "nextTocUrl": "text.下一页@href"
    },
    "searchUrl": "/index.php/book/search?action=search&key={{key}}",
    "weight": 0
  }
]''';
