import assert from "node:assert/strict";
import test from "node:test";
import { adaptTaobaoResult, taobaoEndpointKind } from "../src/search/taobao.ts";

test("Taobao endpoint versions map to stable presentation kinds", () => {
  assert.equal(taobaoEndpointKind("taobao.search_item_list_v1"), "product-list");
  assert.equal(taobaoEndpointKind("taobao.get_shop_item_list_v4"), "product-list");
  assert.equal(taobaoEndpointKind("taobao.get_item_detail_v2"), "async-task");
  assert.equal(taobaoEndpointKind("taobao.get_item_detail_v9"), "product-detail");
  assert.equal(taobaoEndpointKind("taobao.get_item_comment_v3"), "review-list");
  assert.equal(taobaoEndpointKind("taobao.get_social_feed_v1"), "question-list");
  assert.equal(taobaoEndpointKind("taobao.get_item_sale_v1"), "sales-metric");
  assert.equal(taobaoEndpointKind("xiaohongshu.search_note_v4"), undefined);
});

test("Taobao detail v1 flattens grouped properties and omits empty values", () => {
  const result = adaptTaobaoResult("taobao.get_item_detail_v1", { item_id: "42" }, {
    code: 0,
    data: {
      item: { itemId: "42", title: "男士护理套组", images: ["//img.alicdn.com/a.jpg"] },
      itemPrice: { promotionPrice: "99", originalPrice: "129" },
      props: {
        groupProps: [{ "基本信息": [{ "品牌": "珂岸" }, { "产地": "中国" }, { "空字段": "" }] }],
      },
    },
    raw: { duplicate: true },
  });

  assert.ok(result);
  assert.deepEqual(result.presentation.data.properties, [
    { name: "品牌", value: "珂岸" },
    { name: "产地", value: "中国" },
  ]);
  assert.match(result.text, /properties=品牌:珂岸; 产地:中国/);
  assert.doesNotMatch(result.text, /raw|空字段/);
});

test("Taobao detail v4 converts fen prices to yuan", () => {
  const result = adaptTaobaoResult("taobao.get_item_detail_v4", { item_id: "42" }, {
    code: 0,
    data: {
      itemId: "42",
      title: "测试商品",
      DiscountPrice: 15900,
      itemPrice: 19900,
      sku2info: [{ skuId: "sku-1", price: 16900, stock: 3 }],
    },
  });

  assert.ok(result);
  assert.deepEqual(result.presentation.data.prices, [
    { label: "promotion", value: 159, currency: "CNY" },
    { label: "original", value: 199, currency: "CNY" },
  ]);
  assert.equal((result.presentation.data.variants as Array<Record<string, unknown>>)[0].price, 169);
  assert.match(result.text, /promotion:¥159, original:¥199/);
});

test("Taobao reviews keep rich UI fields but hide system reviews from agent context", () => {
  const result = adaptTaobaoResult("taobao.get_item_comment_v3", { item_id: "42", page: 1 }, {
    code: 0,
    data: {
      total: 2,
      currentPageNum: 1,
      maxPage: 1,
      comments: [
        { rateId: "a", content: "系统默认好评", userName: "匿名" },
        { rateId: "b", content: "萃取稳定，奶泡细腻", userName: "买家", propertiesAvg: 5, skuInfo: "白色" },
      ],
    },
  });

  assert.ok(result);
  assert.equal((result.presentation.data.reviews as Array<Record<string, unknown>>).length, 2);
  assert.match(result.text, /萃取稳定，奶泡细腻/);
  assert.match(result.text, /HIDDEN_SYSTEM_REVIEWS 1/);
  assert.doesNotMatch(result.text, /系统默认好评/);
});

test("Taobao Q&A flattens the endpoint's nested list shape", () => {
  const result = adaptTaobaoResult("taobao.get_social_feed_v1", { item_id: "42" }, {
    code: 0,
    data: {
      total: 1,
      list: [[{
        id: "q1",
        title: "可以用咖啡粉吗？",
        subFeeds: [{ title: "可以，配有粉碗", user: { userNick: "店主" } }],
      }]],
    },
  });

  assert.ok(result);
  assert.equal((result.presentation.data.questions as Array<Record<string, unknown>>).length, 1);
  assert.match(result.text, /可以用咖啡粉吗/);
  assert.match(result.text, /可以，配有粉碗/);
});
