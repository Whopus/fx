type JSONObject = Record<string, unknown>;

export interface TaobaoToolPresentation {
  version: 1;
  platform: "taobao";
  kind: "product-list" | "product-detail" | "review-list" | "question-list" | "sales-metric" | "async-task";
  endpoint: string;
  request: JSONObject;
  summary?: JSONObject;
  data: JSONObject;
  warnings?: string[];
}

export interface TaobaoAdaptedResult {
  text: string;
  presentation: TaobaoToolPresentation;
}

function toolPresentation(source: JSONObject): TaobaoToolPresentation {
  const normalized = withoutEmpty(source);
  // These two containers are part of the UI contract even when an upstream
  // endpoint legitimately returns no matching fields.
  normalized.request = object(source.request) ?? {};
  normalized.data = object(source.data) ?? {};
  return normalized as unknown as TaobaoToolPresentation;
}

function object(value: unknown): JSONObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as JSONObject
    : undefined;
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function at(value: unknown, path: string): unknown {
  let current = value;
  for (const segment of path.split(".")) {
    if (Array.isArray(current)) {
      const index = Number(segment);
      if (!Number.isInteger(index)) return undefined;
      current = current[index];
      continue;
    }
    const record = object(current);
    if (!record) return undefined;
    current = record[segment];
  }
  return current;
}

function text(...values: unknown[]): string | undefined {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
    if (typeof value === "number" && Number.isFinite(value)) return String(value);
  }
  return undefined;
}

function number(...values: unknown[]): number | undefined {
  for (const value of values) {
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value === "string" && value.trim()) {
      const parsed = Number(value.replace(/[,￥¥]/g, ""));
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return undefined;
}

function boolean(...values: unknown[]): boolean | undefined {
  for (const value of values) {
    if (typeof value === "boolean") return value;
    if (value === "true" || value === "1" || value === 1) return true;
    if (value === "false" || value === "0" || value === 0) return false;
  }
  return undefined;
}

function withoutEmpty<T extends JSONObject>(source: T): T {
  const result: JSONObject = {};
  for (const [key, value] of Object.entries(source)) {
    if (value === undefined || value === null) continue;
    if (typeof value === "string" && !value.trim()) continue;
    if (Array.isArray(value)) {
      const items = value
        .map((item) => object(item) ? withoutEmpty(object(item)!) : item)
        .filter((item) => item !== undefined && item !== null && item !== "" && (!Array.isArray(item) || item.length > 0) && (!object(item) || Object.keys(object(item)!).length > 0));
      if (items.length) result[key] = items;
      continue;
    }
    if (object(value)) {
      const nested = withoutEmpty(object(value)!);
      if (Object.keys(nested).length) result[key] = nested;
      continue;
    }
    result[key] = value;
  }
  return result as T;
}

function normalizeURL(value: unknown): string | undefined {
  const raw = text(value);
  if (!raw || raw === "0") return undefined;
  if (raw.startsWith("//")) return `https:${raw}`;
  if (/^https?:\/\//i.test(raw)) return raw;
  return undefined;
}

function itemURL(id: string | undefined, candidate?: unknown): string | undefined {
  const url = normalizeURL(candidate);
  if (url && !/[?&]id=(?:&|$)/.test(url)) return url;
  return id ? `https://item.taobao.com/item.htm?id=${encodeURIComponent(id)}` : url;
}

function uniqueURLs(values: unknown[], limit = 10): string[] {
  return [...new Set(values.map(normalizeURL).filter((value): value is string => Boolean(value)))].slice(0, limit);
}

function meaningfulDiscount(value: unknown): string | undefined {
  const label = text(value);
  return label && label !== "0" ? label : undefined;
}

function normalizeMarketplace(value: unknown): "taobao" | "tmall" | undefined {
  if (value === true) return "tmall";
  const normalized = text(value)?.toLowerCase();
  if (normalized === "tmall" || normalized === "b") return "tmall";
  if (normalized === "taobao" || normalized === "c") return "taobao";
  return undefined;
}

function normalizeSales(label: string, value: unknown): JSONObject | undefined {
  const normalized = text(value);
  return normalized === undefined ? undefined : { label, value: normalized };
}

function normalizeListProduct(raw: unknown, mode: "search" | "shop-v1" | "shop-v2" | "shop-v4"): JSONObject | undefined {
  const source = object(raw);
  if (!source) return undefined;
  const id = text(source.itemId, source.item_id, source.num_iid, source.id);
  const title = text(source.itemName, source.title, source.subject);
  if (!id && !title) return undefined;

  let price = number(source.priceZKYuanDouble, source.discntPriceYuan, source.promotion_price, source.price);
  let originalPrice = number(source.priceYuanDouble, source.reservePrice, source.originalPrice, source.orginal_price);
  if (mode === "shop-v1") {
    price = number(source.zkPrice, source.price, price);
    originalPrice = number(source.reservePrice, source.originalPrice, originalPrice);
  }
  if (price !== undefined && originalPrice !== undefined && originalPrice <= price) originalPrice = undefined;

  const sales = mode === "shop-v2"
    ? normalizeSales("30-day sales", source.soldCount30Day)
      ?? normalizeSales("30-day orders", source.orderCount30Day)
      ?? normalizeSales("buyers", source.orderPayUV)
    : mode === "shop-v4"
      ? normalizeSales("sold", source.vagueTotalSoldQuantity)
        ?? normalizeSales("365-day sales", source.sold365)
      : normalizeSales("buyers", source.orderPayUV)
        ?? normalizeSales("sold", source.totalSoldQuantity)
        ?? normalizeSales("sales", source.sales);

  const imageURL = normalizeURL(source.picUrlFull ?? source.itemPic ?? source.picUrl ?? source.image);
  return withoutEmpty({
    id,
    title,
    subtitle: text(source.itemSubName, source.subtitle, source.recommendDescription),
    imageURL,
    url: itemURL(id, source.itemUrl ?? source.detailUrl ?? source.detail_url),
    price,
    originalPrice,
    discountLabel: meaningfulDiscount(source.discntType ?? source.discountType),
    sales,
    reviewCount: text(source.commentCount, source.reviewCount),
    shop: withoutEmpty({ id: text(source.shopId), name: text(source.shopName) }),
    location: text(source.itemLoc, source.location),
    marketplace: normalizeMarketplace(source.tmall ?? source.shopType ?? source.sellerType),
  });
}

function pageSummary(raw: unknown): JSONObject {
  const source = object(raw) ?? {};
  return withoutEmpty({
    page: number(source.pageNo, source.currentPage, source.currentPageNum, source.pageNum),
    pageSize: number(source.pageSize),
    totalItems: number(source.totalItems, source.totalCount, source.total),
    totalPages: number(source.totalPages, source.maxPage),
    hasNext: boolean(source.hasNext, source.hasNextPage, source.hasMore),
    nextPage: number(source.nextNo),
  });
}

function normalizeShop(raw: unknown): JSONObject | undefined {
  const source = object(raw);
  if (!source) return undefined;
  const result = withoutEmpty({
    id: text(source.shopId, source.shop_id),
    sellerId: text(source.sellerId, source.seller_id, source.userId),
    name: text(source.shopName, source.shop_title, source.shopTitle, source.seller_title),
    iconURL: normalizeURL(source.picUrl ?? source.shopIcon ?? source.shop_icon),
    url: normalizeURL(source.shopUrl ?? source.shop_url ?? source.taoShopUrl),
    scores: withoutEmpty({
      description: number(source.descriptionMatchScore),
      service: number(source.serviceScore),
      delivery: number(source.deliverScore),
    }),
  });
  return Object.keys(result).length ? result : undefined;
}

function requestInfo(params: JSONObject): JSONObject {
  return withoutEmpty({
    query: text(params.keyword),
    itemId: text(params.item_id),
    shopId: text(params.shop_id),
    sellerId: text(params.seller_id, params.user_id),
    page: number(params.page),
    sort: text(params.sort),
    tmallOnly: params.tmall === true ? true : undefined,
    minimumPrice: text(params.start_price),
    maximumPrice: text(params.end_price),
  });
}

function responseData(value: unknown): unknown {
  const root = object(value);
  return root && root.data !== undefined ? root.data : value;
}

function warnings(value: unknown): string[] | undefined {
  const result = array(object(value)?.warnings).map((item) => text(item)).filter((item): item is string => Boolean(item));
  return result.length ? result : undefined;
}

function normalizeProductList(endpointID: string, params: JSONObject, value: unknown): TaobaoToolPresentation {
  const data = object(responseData(value)) ?? {};
  let rawItems: unknown[] = [];
  let summary: JSONObject = {};
  let shop: JSONObject | undefined;
  let mode: "search" | "shop-v1" | "shop-v2" | "shop-v4" = "search";

  if (endpointID === "taobao.search_item_list_v1") {
    const model = object(data.model) ?? data;
    rawItems = array(model.itemList);
    summary = pageSummary(model.page);
  } else if (endpointID === "taobao.get_shop_item_list_v2") {
    mode = "shop-v2";
    const httpData = object(data.httpData) ?? data;
    const itemModule = object(httpData.itemListModuleResponse) ?? {};
    rawItems = array(itemModule.itemList);
    summary = pageSummary(itemModule.page);
    shop = normalizeShop(array(object(httpData.shopListModuleResponse)?.shopList)[0]);
  } else if (endpointID === "taobao.get_shop_item_list_v4") {
    mode = "shop-v4";
    rawItems = array(data.result)
      .map((entry) => object(entry))
      .filter((entry): entry is JSONObject => entry !== undefined && text(entry.blockType)?.toLowerCase() === "item")
      .map((entry) => entry.blockContent);
    summary = withoutEmpty({ hasNext: boolean(data.hasNext) });
  } else {
    mode = "shop-v1";
    rawItems = array(data.resultList ?? data.itemList ?? data.items);
    summary = pageSummary(data.page ?? data.pagination);
  }

  const items = rawItems.map((item) => normalizeListProduct(item, mode)).filter((item): item is JSONObject => Boolean(item));
  if (summary.page === undefined) summary.page = number(params.page) ?? 1;
  if (summary.pageSize === undefined && items.length) summary.pageSize = items.length;
  if (summary.hasNext === undefined) {
    const next = number(at(value, "next_step.params.page"));
    if (next !== undefined) {
      summary.hasNext = true;
      summary.nextPage = next;
    }
  }

  return toolPresentation({
    version: 1,
    platform: "taobao",
    kind: "product-list",
    endpoint: endpointID,
    request: requestInfo(params),
    summary: withoutEmpty({ ...summary, count: items.length }),
    data: withoutEmpty({ shop, items }),
    warnings: warnings(value),
  });
}

function normalizeProperties(values: unknown, nameKeys = ["name", "key", "pname"], valueKeys = ["value", "vname"]): JSONObject[] {
  const result: JSONObject[] = [];
  const visit = (entry: unknown): void => {
    if (result.length >= 40) return;
    if (Array.isArray(entry)) {
      for (const item of entry) visit(item);
      return;
    }
    const source = object(entry);
    if (!source) return;
    const named = withoutEmpty({
      name: text(...nameKeys.map((key) => source[key])),
      value: text(...valueKeys.map((key) => source[key])),
    });
    if (named.name && named.value) {
      result.push(named);
      return;
    }
    // Some versions group properties as { "基本信息": [{ "品牌": "…" }] }.
    for (const [name, value] of Object.entries(source)) {
      if (result.length >= 40) break;
      const scalar = text(value);
      if (scalar !== undefined) result.push({ name, value: scalar });
      else visit(value);
    }
  };
  visit(values);
  return result;
}

function normalizeOptionGroups(values: unknown): JSONObject[] {
  if (object(values)) {
    return Object.entries(object(values)!).slice(0, 12).map(([name, rawValues]) => withoutEmpty({
      name,
      values: object(rawValues)
        ? Object.values(object(rawValues)!).slice(0, 30).map((value) => text(array(value)[0])).filter(Boolean)
        : array(rawValues).slice(0, 30).map((value) => text(value)).filter(Boolean),
    })).filter((group) => array(group.values).length > 0);
  }
  return array(values).slice(0, 12).map((entry) => {
    const source = object(entry) ?? {};
    const rawValues = array(source.values ?? source.itemPropertyValues);
    return withoutEmpty({
      name: text(source.name, source.propertyName, source.pname),
      values: rawValues.slice(0, 30).map((value) => {
        const item = object(value);
        return text(item?.name, item?.value, item?.vname, value);
      }).filter(Boolean),
    });
  }).filter((group) => Boolean(group.name && array(group.values).length));
}

function price(label: string, value: unknown, divisor = 1): JSONObject | undefined {
  const parsed = number(value);
  return parsed === undefined ? undefined : { label, value: parsed / divisor, currency: "CNY" };
}

function dedupePrices(values: Array<JSONObject | undefined>): JSONObject[] {
  const result: JSONObject[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    if (!value) continue;
    const key = `${value.label}:${value.value}:${value.minimum}:${value.maximum}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(value);
  }
  return result;
}

function normalizeVariants(values: unknown, divisor = 1): JSONObject[] {
  const candidates = object(values) && Array.isArray(object(values)?.sku) ? array(object(values)?.sku) : array(values);
  return candidates.slice(0, 60).map((entry) => {
    const source = object(entry) ?? {};
    const attributes = array(source.skuAttr).map((attribute) => {
      const item = object(attribute) ?? {};
      return text(item.enumValue, item.value, item.name);
    }).filter(Boolean);
    const propertiesName = text(source.properties_name, source.skuName, source.name);
    return withoutEmpty({
      id: text(source.skuId, source.sku_id, source.skuNo),
      name: propertiesName,
      options: attributes,
      imageURL: normalizeURL(source.skuPicUrl ?? source.image),
      price: number(source.finalSkuPrice, source.finalPrice, source.promotion_price, source.price) !== undefined
        ? number(source.finalSkuPrice, source.finalPrice, source.promotion_price, source.price)! / divisor
        : undefined,
      originalPrice: number(source.itemPrice, source.orginal_price, source.orign_price, source.originalPrice) !== undefined
        ? number(source.itemPrice, source.orginal_price, source.orign_price, source.originalPrice)! / divisor
        : undefined,
      stock: number(source.stock, source.quantity),
    });
  }).filter((variant) => Object.keys(variant).length > 0);
}

function variantSummary(variants: JSONObject[]): JSONObject | undefined {
  if (!variants.length) return undefined;
  const prices = variants.map((variant) => number(variant.price)).filter((value): value is number => value !== undefined);
  const stocks = variants.map((variant) => number(variant.stock)).filter((value): value is number => value !== undefined);
  return withoutEmpty({
    count: variants.length,
    inStockCount: stocks.length ? stocks.filter((value) => value > 0).length : undefined,
    minimumPrice: prices.length ? Math.min(...prices) : undefined,
    maximumPrice: prices.length ? Math.max(...prices) : undefined,
  });
}

function normalizeDetail(endpointID: string, params: JSONObject, value: unknown): TaobaoToolPresentation {
  const data = object(responseData(value)) ?? {};
  let detail: JSONObject;

  if (endpointID === "taobao.get_item_detail_v1") {
    const item = object(data.item) ?? {};
    const itemPrice = object(data.itemPrice) ?? {};
    const main = object(data.mainItemInfo) ?? {};
    const seller = normalizeShop(data.seller);
    const id = text(item.itemId, main.itemId, params.item_id);
    const variants = normalizeVariants(at(data, "itemSkuDO.skuList") ?? at(data, "itemSkuDO.skuDOList"));
    detail = withoutEmpty({
      id,
      title: text(item.title, main.itemName),
      marketplace: normalizeMarketplace(item.seoItemType),
      url: itemURL(id),
      mainImageURL: normalizeURL(array(item.images)[0] ?? main.pic),
      imageURLs: uniqueURLs(array(item.images)),
      videoURL: normalizeURL(at(item, "videos.0.videoUrl")),
      prices: dedupePrices([
        price("after-coupon", at(main, "taobaoPromotionModel.finalPromotionInfo.finalPromotionPrice")),
        price("promotion", at(main, "promotionModel.promotionPriceModel.promotionPrice")),
        price("after-coupon", main.afterCouponAmountPrice),
        price("promotion", itemPrice.promotionPrice),
        price("original", itemPrice.originalPrice),
      ]),
      sales: [normalizeSales("sold", item.sellCount ?? at(data, "itemTrade.soldQuantityTotal"))].filter(Boolean),
      location: text(item.location),
      shop: seller,
      properties: normalizeProperties(at(data, "props.groupProps")),
      optionGroups: normalizeOptionGroups(at(data, "itemSkuDO.skuPropertyList")),
      variantSummary: variantSummary(variants),
      variants,
      availability: withoutEmpty({ exists: boolean(data.itemExist), areaLimited: boolean(data.areaLimit) }),
    });
  } else if (endpointID === "taobao.get_item_detail_v3") {
    const id = text(data.num_iid, params.item_id);
    const variants = normalizeVariants(data.skus);
    detail = withoutEmpty({
      id,
      title: text(data.title),
      marketplace: normalizeMarketplace(data.tmall),
      url: itemURL(id, data.detail_url),
      mainImageURL: normalizeURL(data.pic_url ?? at(data, "item_imgs.0.url")),
      imageURLs: uniqueURLs(array(data.item_imgs).map((entry) => object(entry)?.url)),
      videoURL: normalizeURL(at(data, "video.url")),
      prices: dedupePrices([price("price", data.price), price("original", data.orginal_price)]),
      sales: [normalizeSales("sold", data.total_sold ?? data.sales)].filter(Boolean),
      brand: text(data.brand),
      location: text(data.location),
      stock: number(data.num),
      shop: normalizeShop({ shopId: data.shop_id, sellerId: data.seller_id, ...object(data.seller_info) }),
      properties: normalizeProperties(data.props),
      optionGroups: normalizeOptionGroups(data.props_img ?? data.props),
      variantSummary: variantSummary(variants),
      variants,
    });
  } else if (endpointID === "taobao.get_item_detail_v4") {
    const id = text(data.itemId, params.item_id);
    const variants = normalizeVariants(data.sku2info, 100);
    detail = withoutEmpty({
      id,
      title: text(data.title),
      marketplace: normalizeMarketplace(data.shopType),
      url: itemURL(id),
      mainImageURL: normalizeURL(data.itemPic),
      imageURLs: uniqueURLs(array(data.images)),
      prices: dedupePrices([price("promotion", data.DiscountPrice, 100), price("original", data.itemPrice, 100)]),
      shop: normalizeShop({ shopName: data.shopName }),
      optionGroups: normalizeOptionGroups(data.skuBase),
      variantSummary: variantSummary(variants),
      variants,
    });
  } else if (endpointID === "taobao.get_item_detail_v5") {
    const item = object(data.item) ?? {};
    const delivery = object(data.delivery) ?? {};
    const id = text(item.num_iid, params.item_id);
    const variants = normalizeVariants(item.sku_base);
    detail = withoutEmpty({
      id,
      title: text(item.title),
      url: itemURL(id, item.detail_url),
      mainImageURL: normalizeURL(array(item.images)[0]),
      imageURLs: uniqueURLs(array(item.images)),
      videoURL: normalizeURL(item.video),
      prices: dedupePrices([price("promotion", at(item, "skus.promotion_price")), price("original", at(item, "skus.price"))]),
      sales: [normalizeSales("sold", item.sales)].filter(Boolean),
      brand: text(item.brandName),
      shop: normalizeShop(data.seller),
      properties: normalizeProperties(item.properties),
      optionGroups: normalizeOptionGroups(item.sku_props),
      variantSummary: variantSummary(variants),
      variants,
      shipping: withoutEmpty({ from: text(delivery.from), to: text(delivery.to), fee: number(delivery.delivery_fee) }),
    });
  } else if (endpointID === "taobao.get_item_detail_v7") {
    const id = text(data.spuNo, params.item_id);
    const variants = normalizeVariants(data.skuVoList);
    detail = withoutEmpty({
      id,
      title: text(data.subject),
      marketplace: normalizeMarketplace(data.channel),
      url: itemURL(id, data.detailUrl),
      mainImageURL: normalizeURL(data.mainImg),
      imageURLs: uniqueURLs(array(data.imageList)),
      prices: dedupePrices([price("price", data.price), price("original", data.originalPrice)]),
      sales: [normalizeSales("monthly sold", data.monthSold)].filter(Boolean),
      minimumOrder: number(data.startQuantity),
      shop: normalizeShop({ shopName: data.shopName }),
      properties: normalizeProperties(data.baseAttrList),
      variantSummary: variantSummary(variants),
      variants,
      shipping: withoutEmpty({ fee: number(data.expressFee) }),
      availability: withoutEmpty({ hasStock: boolean(data.hadTotalStock), prohibited: boolean(data.productProhibitedFromSale) }),
    });
  } else {
    const id = text(data.itemId, params.item_id);
    const variants = normalizeVariants(data.skus, 100);
    detail = withoutEmpty({
      id,
      title: text(data.title),
      marketplace: normalizeMarketplace(data.sellerType),
      url: itemURL(id),
      mainImageURL: normalizeURL(at(data, "item_imgs.0.url") ?? at(data, "mainItemInfo.pic")),
      imageURLs: uniqueURLs(array(data.item_imgs).map((entry) => object(entry)?.url)),
      videoURL: normalizeURL(data.videoUrl),
      prices: dedupePrices([price("after-coupon", at(data, "mainItemInfo.afterCouponAmountPrice")), price("price", data.price)]),
      sales: [normalizeSales("sold", data.totalCount)].filter(Boolean),
      location: text(data.location),
      stock: number(data.num),
      shop: normalizeShop({ shopId: data.shopId, userId: data.userId, shopName: data.shopName }),
      properties: normalizeProperties(data.attribute),
      optionGroups: normalizeOptionGroups(data.specs ?? data.props),
      variantSummary: variantSummary(variants),
      variants,
    });
  }

  return toolPresentation({
    version: 1,
    platform: "taobao",
    kind: "product-detail",
    endpoint: endpointID,
    request: requestInfo(params),
    data: detail,
    warnings: warnings(value),
  });
}

function normalizeReview(raw: unknown): JSONObject | undefined {
  const source = object(raw);
  if (!source) return undefined;
  const content = text(source.content);
  if (!content && !source.append && !array(source.appendList).length && !array(source.appendRateList).length) return undefined;
  const appendSource = object(source.append)
    ?? object(array(source.appendList)[0])
    ?? object(array(source.appendRateList)[0]);
  return withoutEmpty({
    id: text(source.rateId, source.id),
    author: text(at(source, "user.nick"), source.userName),
    avatarURL: normalizeURL(at(source, "user.avatar") ?? source.headPic),
    score: number(source.propertiesAvg, source.commentScore),
    content,
    date: text(source.date, source.dateTime),
    sku: text(at(source, "auction.sku"), source.skuInfo),
    images: uniqueURLs([...array(source.photos).map((entry) => object(entry)?.url ?? entry), ...array(source.images)], 6),
    videoURL: normalizeURL(at(source, "video.url") ?? source.video),
    likeCount: number(source.likeCount),
    usefulCount: number(source.useful),
    sellerReply: text(object(source.reply)?.content, source.reply),
    append: appendSource ? withoutEmpty({
      content: text(appendSource.content),
      daysLater: number(appendSource.appendIntervalDay, appendSource.dayAfterConfirm),
      images: uniqueURLs(array(appendSource.images), 4),
    }) : undefined,
    systemGenerated: content?.includes("系统默认好评") ? true : undefined,
  });
}

function normalizeReviews(endpointID: string, params: JSONObject, value: unknown): TaobaoToolPresentation {
  const data = object(responseData(value)) ?? {};
  const reviews = array(data.comments ?? data.rateList).map(normalizeReview).filter((item): item is JSONObject => Boolean(item));
  const keywords = array(data.keywords).slice(0, 12).map((entry) => {
    const source = object(entry) ?? {};
    const kind = number(source.type);
    return withoutEmpty({ text: text(source.word), count: number(source.count), sentiment: kind === -1 ? "negative" : kind === 1 ? "positive" : undefined });
  }).filter((item) => Boolean(item.text));
  const summary = withoutEmpty({
    ...pageSummary(data),
    totalItems: number(data.total),
    totalText: text(data.totalFuzzy),
    mediaReviewCount: number(data.hasMediaCount),
    appendedReviewCount: number(data.hasAppendCount),
    count: reviews.length,
    informativeCount: reviews.filter((review) => review.systemGenerated !== true).length,
  });
  return toolPresentation({
    version: 1,
    platform: "taobao",
    kind: "review-list",
    endpoint: endpointID,
    request: requestInfo(params),
    summary,
    data: withoutEmpty({ keywords, reviews }),
    warnings: warnings(value),
  });
}

function normalizeQuestion(raw: unknown): JSONObject | undefined {
  const source = object(raw);
  if (!source) return undefined;
  const answers = array(source.subFeeds ?? source.answerList).slice(0, 8).map((entry) => {
    const item = object(entry) ?? {};
    return withoutEmpty({
      answer: text(item.title, item.answerContent),
      author: text(at(item, "user.userNick"), item.userNick),
      date: text(item.gmtCreate, item.createTime),
    });
  }).filter((item) => Boolean(item.answer));
  return withoutEmpty({
    id: text(source.id),
    question: text(source.title, source.askContent),
    author: text(source.askUserNick),
    date: text(source.gmtCreate, source.createTime),
    answerCount: number(source.subFeedsCount) ?? answers.length,
    url: normalizeURL(source.targetUrl),
    answers,
  });
}

function normalizeQuestions(endpointID: string, params: JSONObject, value: unknown): TaobaoToolPresentation {
  const data = object(responseData(value)) ?? {};
  const rawQuestions = array(data.list).flatMap((entry) => Array.isArray(entry) ? entry : [entry]);
  const questions = rawQuestions.map(normalizeQuestion).filter((item): item is JSONObject => Boolean(item));
  const item = object(data.item) ?? {};
  const tags = array(at(item, "tags.list")).slice(0, 12).map((entry) => {
    const source = object(entry) ?? {};
    return withoutEmpty({ text: text(source.keyword), count: number(source.count) });
  }).filter((entry) => Boolean(entry.text));
  return toolPresentation({
    version: 1,
    platform: "taobao",
    kind: "question-list",
    endpoint: endpointID,
    request: requestInfo(params),
    summary: withoutEmpty({ ...pageSummary(data.pagination), totalItems: number(data.total, item.questionCount), count: questions.length }),
    data: withoutEmpty({
      item: withoutEmpty({ title: text(item.itemTitle), imageURL: normalizeURL(item.itemPic), url: normalizeURL(item.itemUrl) }),
      tags,
      questions,
    }),
    warnings: warnings(value),
  });
}

function normalizeSalesMetric(endpointID: string, params: JSONObject, value: unknown): TaobaoToolPresentation {
  const data = object(responseData(value)) ?? {};
  return toolPresentation({
    version: 1,
    platform: "taobao",
    kind: "sales-metric",
    endpoint: endpointID,
    request: requestInfo(params),
    data: withoutEmpty({
      itemId: text(params.item_id),
      value: text(data.sales, data.sale, data.monthSold, data.orderPayUV, data.total_sold, data.total),
      period: text(data.period),
    }),
    warnings: warnings(value),
  });
}

function normalizeTask(endpointID: string, params: JSONObject, value: unknown): TaobaoToolPresentation {
  const data = object(responseData(value)) ?? {};
  return toolPresentation({
    version: 1,
    platform: "taobao",
    kind: "async-task",
    endpoint: endpointID,
    request: requestInfo(params),
    data: withoutEmpty({
      itemId: text(params.item_id, data.itemId),
      taskId: text(data.taskId, data.task_id, data.id),
      status: text(data.status, data.state),
      progress: number(data.progress),
      resultURL: normalizeURL(data.resultURL ?? data.result_url ?? data.downloadUrl),
      expiresAt: text(data.expiresAt, data.expires_at),
      message: text(data.message),
    }),
    warnings: warnings(value),
  });
}

function compact(value: unknown, maximum = 320): string | undefined {
  const normalized = text(value)?.replace(/\s+/g, " ").trim();
  if (!normalized) return undefined;
  return normalized.length > maximum ? `${normalized.slice(0, maximum - 1)}…` : normalized;
}

function money(value: unknown): string | undefined {
  const amount = number(value);
  if (amount === undefined) return undefined;
  return `¥${Number.isInteger(amount) ? amount : amount.toFixed(2).replace(/0+$/, "").replace(/\.$/, "")}`;
}

function formatProductList(presentation: TaobaoToolPresentation): string {
  const request = presentation.request;
  const summary = presentation.summary ?? {};
  const data = presentation.data;
  const items = array(data.items).map(object).filter((item): item is JSONObject => Boolean(item));
  const header = [
    "TAOBAO_PRODUCTS",
    request.query ? `q=${JSON.stringify(request.query)}` : undefined,
    summary.page ? `page=${summary.page}${summary.totalPages ? `/${summary.totalPages}` : ""}` : undefined,
    summary.totalItems !== undefined ? `total=${summary.totalItems}` : undefined,
    `count=${items.length}`,
  ].filter(Boolean).join(" ");
  const lines = [header, "item_url=https://item.taobao.com/item.htm?id={id}"];
  for (const [index, item] of items.slice(0, 20).entries()) {
    const sales = object(item.sales);
    const shop = object(item.shop);
    lines.push([
      `${index + 1}`,
      item.id ? `id=${item.id}` : undefined,
      money(item.price),
      item.originalPrice ? `original=${money(item.originalPrice)}` : undefined,
      sales?.value ? `${sales.label}=${sales.value}` : undefined,
      shop?.name,
      item.location,
      compact(item.title, 180),
    ].filter(Boolean).join(" | "));
  }
  if (items.length > 20) lines.push(`OMITTED ${items.length - 20} products from agent context`);
  if (summary.nextPage) lines.push(`NEXT page=${summary.nextPage}`);
  return lines.join("\n");
}

function formatDetail(presentation: TaobaoToolPresentation): string {
  const item = presentation.data;
  const lines = [`TAOBAO_PRODUCT id=${item.id ?? presentation.request.itemId ?? "unknown"}`];
  if (item.title) lines.push(`title=${compact(item.title, 240)}`);
  if (item.url) lines.push(`url=${item.url}`);
  const prices = array(item.prices).map(object).filter((entry): entry is JSONObject => Boolean(entry));
  if (prices.length) lines.push(`prices=${prices.map((entry) => `${entry.label}:${money(entry.value) ?? ""}`).join(", ")}`);
  for (const sale of array(item.sales).map(object).filter((entry): entry is JSONObject => Boolean(entry))) {
    if (sale.value) lines.push(`${sale.label}=${sale.value}`);
  }
  if (item.brand) lines.push(`brand=${item.brand}`);
  if (item.location) lines.push(`location=${item.location}`);
  if (item.stock !== undefined) lines.push(`stock=${item.stock}`);
  if (item.minimumOrder !== undefined) lines.push(`minimum_order=${item.minimumOrder}`);
  const shop = object(item.shop);
  if (shop?.name || shop?.id) lines.push(`shop=${[shop.name, shop.id ? `id:${shop.id}` : undefined].filter(Boolean).join(" | ")}`);
  const shipping = object(item.shipping);
  if (shipping && Object.keys(shipping).length) lines.push(`shipping=${Object.entries(shipping).map(([key, value]) => `${key}:${value}`).join(", ")}`);
  const properties = array(item.properties).map(object).filter((entry): entry is JSONObject => Boolean(entry));
  if (properties.length) lines.push(`properties=${properties.slice(0, 30).map((entry) => `${entry.name}:${compact(entry.value, 120)}`).join("; ")}`);
  const groups = array(item.optionGroups).map(object).filter((entry): entry is JSONObject => Boolean(entry));
  for (const group of groups.slice(0, 10)) {
    const values = array(group.values).map((value) => compact(value, 80)).filter(Boolean);
    if (group.name && values.length) lines.push(`option.${group.name}=${values.slice(0, 12).join(", ")}${values.length > 12 ? `, …+${values.length - 12}` : ""}`);
  }
  const variants = object(item.variantSummary);
  if (variants) lines.push(`variants=${Object.entries(variants).map(([key, value]) => `${key}:${value}`).join(", ")}`);
  const availability = object(item.availability);
  if (availability && Object.keys(availability).length) lines.push(`availability=${Object.entries(availability).map(([key, value]) => `${key}:${value}`).join(", ")}`);
  return lines.join("\n").slice(0, 12_000);
}

function formatReviews(presentation: TaobaoToolPresentation): string {
  const summary = presentation.summary ?? {};
  const reviews = array(presentation.data.reviews).map(object).filter((item): item is JSONObject => Boolean(item));
  const informative = reviews.filter((review) => review.systemGenerated !== true);
  const lines = [[
    "TAOBAO_REVIEWS",
    presentation.request.itemId ? `item=${presentation.request.itemId}` : undefined,
    summary.page ? `page=${summary.page}${summary.totalPages ? `/${summary.totalPages}` : ""}` : undefined,
    summary.totalText ? `total=${summary.totalText}` : summary.totalItems !== undefined ? `total=${summary.totalItems}` : undefined,
    `returned=${reviews.length}`,
    `informative=${informative.length}`,
  ].filter(Boolean).join(" ")];
  const keywords = array(presentation.data.keywords).map(object).filter((item): item is JSONObject => Boolean(item));
  if (keywords.length) lines.push(`keywords=${keywords.map((item) => `${item.text}${item.count !== undefined ? `(${item.count})` : ""}`).join(", ")}`);
  for (const [index, review] of informative.slice(0, 10).entries()) {
    const append = object(review.append);
    lines.push([
      `${index + 1}`,
      review.score !== undefined ? `score=${review.score}` : undefined,
      review.author,
      review.date,
      review.sku ? `sku=${compact(review.sku, 100)}` : undefined,
      compact(review.content, 700),
      append?.content ? `follow-up:${compact(append.content, 300)}` : undefined,
    ].filter(Boolean).join(" | "));
  }
  if (reviews.length > informative.length) lines.push(`HIDDEN_SYSTEM_REVIEWS ${reviews.length - informative.length}`);
  return lines.join("\n").slice(0, 12_000);
}

function formatQuestions(presentation: TaobaoToolPresentation): string {
  const summary = presentation.summary ?? {};
  const questions = array(presentation.data.questions).map(object).filter((item): item is JSONObject => Boolean(item));
  const lines = [[
    "TAOBAO_QUESTIONS",
    presentation.request.itemId ? `item=${presentation.request.itemId}` : undefined,
    summary.page ? `page=${summary.page}` : undefined,
    summary.totalItems !== undefined ? `total=${summary.totalItems}` : undefined,
    `count=${questions.length}`,
  ].filter(Boolean).join(" ")];
  for (const [index, question] of questions.slice(0, 10).entries()) {
    lines.push(`${index + 1} | ${compact(question.question, 300) ?? "Question"}${question.answerCount !== undefined ? ` | answers=${question.answerCount}` : ""}`);
    for (const answer of array(question.answers).map(object).filter((item): item is JSONObject => Boolean(item)).slice(0, 3)) {
      lines.push(`  - ${compact(answer.answer, 400)}${answer.author ? ` — ${answer.author}` : ""}`);
    }
  }
  return lines.join("\n").slice(0, 12_000);
}

function formatOther(presentation: TaobaoToolPresentation): string {
  const prefix = presentation.kind === "sales-metric" ? "TAOBAO_SALES" : "TAOBAO_TASK";
  const fields = Object.entries(presentation.data).map(([key, value]) => `${key}=${typeof value === "string" ? compact(value, 500) : JSON.stringify(value)}`);
  return [prefix, ...fields].join("\n");
}

function resultText(presentation: TaobaoToolPresentation): string {
  switch (presentation.kind) {
    case "product-list": return formatProductList(presentation);
    case "product-detail": return formatDetail(presentation);
    case "review-list": return formatReviews(presentation);
    case "question-list": return formatQuestions(presentation);
    default: return formatOther(presentation);
  }
}

export function taobaoEndpointKind(endpointID: string): TaobaoToolPresentation["kind"] | undefined {
  if (endpointID === "taobao.search_item_list_v1" || endpointID.startsWith("taobao.get_shop_item_list_")) return "product-list";
  if (endpointID === "taobao.get_item_detail_v2") return "async-task";
  if (endpointID.startsWith("taobao.get_item_detail_")) return "product-detail";
  if (endpointID.startsWith("taobao.get_item_comment_")) return "review-list";
  if (endpointID.startsWith("taobao.get_social_feed_")) return "question-list";
  if (endpointID.startsWith("taobao.get_item_sale_")) return "sales-metric";
  return undefined;
}

export function adaptTaobaoResult(endpointID: string, params: JSONObject, value: unknown): TaobaoAdaptedResult | undefined {
  const kind = taobaoEndpointKind(endpointID);
  if (!kind) return undefined;
  const presentation = kind === "product-list"
    ? normalizeProductList(endpointID, params, value)
    : kind === "product-detail"
      ? normalizeDetail(endpointID, params, value)
      : kind === "review-list"
        ? normalizeReviews(endpointID, params, value)
        : kind === "question-list"
          ? normalizeQuestions(endpointID, params, value)
          : kind === "sales-metric"
            ? normalizeSalesMetric(endpointID, params, value)
            : normalizeTask(endpointID, params, value);
  return { text: resultText(presentation), presentation };
}

export function searchBusinessError(value: unknown): string | undefined {
  const root = object(value);
  if (!root) return undefined;
  const code = number(root.code, at(root, "error.upstream_code"));
  const explicitlyFailed = root.success === false;
  if (!explicitlyFailed && (code === undefined || code === 0)) return undefined;
  const message = text(at(root, "error.message"), root.message) ?? "The search service returned a business error.";
  return code !== undefined ? `[${code}] ${message}` : message;
}
