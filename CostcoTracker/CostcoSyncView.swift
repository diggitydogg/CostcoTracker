import SwiftUI
import WebKit

// MARK: - Costco Purchase Sync

enum CostcoSyncSessionMode: String {
    case fullSync
    case warehouseOnly
}


struct CostcoSyncView: UIViewRepresentable {

    var syncTrigger: Int
    var sessionMode: CostcoSyncSessionMode
    var onlineDetailPlan: String
    var onlineDetailPlanTrigger: Int
    var onMessage: (String) -> Void

    private var bulkJavaScript: String {
        let sessionModeValue = sessionMode.rawValue

        return #"""
(function () {

    if (window.__costcoBulkInstalled) {
        return "already installed";
    }

    window.__costcoBulkInstalled = true;

    const isTopFrame = window.top === window;

    const endpoint =
        "https://ecom-api.costco.com/ebusiness/order/v1/orders/graphql";

    const clientIdentifier =
        "481b1aec-aa3b-454b-b81b-48187e28f205";

    const nativeFetch =
        window.fetch.bind(window);

    const sessionMode =
        "\#(sessionModeValue)";

    const state = {
        headers: null,
        ready: false,
        warehouseReady: false,
        started: false,
        busy: false,
        onlineScanStarted: false,
        onlineScanBusy: false,
        onlineSummaries: new Map(),
        onlineListingResponseCount: 0,
        incrementalDetailBusy: false,
        lastOnlinePages: null
    };


    // MARK: Messaging

    function post(message) {
        try {
            window.webkit
                .messageHandlers
                .costcoSync
                .postMessage(
                    JSON.stringify(message)
                );
        } catch (_) {}
    }


    function progress(message) {
        if (isTopFrame) {
            post({
                syncProgress: message
            });
        }
    }


    function error(message) {
        if (isTopFrame) {
            post({
                syncError: message
            });
        }
    }


    function wait(milliseconds) {
        return new Promise(
            resolve =>
                setTimeout(
                    resolve,
                    milliseconds
                )
        );
    }


    function isGraphQL(url) {
        return String(url || "")
            .includes(
                "/ebusiness/order/v1/orders/graphql"
            );
    }


    // MARK: Costco Authentication

    function bestHeaders(candidate) {

        const headers =
            new Headers(
                candidate || {}
            );

        let clientID = "";
        let token = "";

        try {
            clientID =
                localStorage.getItem(
                    "clientID"
                ) || "";

            token =
                localStorage.getItem(
                    "idToken"
                ) || "";

        } catch (_) {}


        if (
            !headers.has(
                "costco-x-wcs-clientid"
            ) &&
            clientID
        ) {
            headers.set(
                "costco-x-wcs-clientid",
                clientID
            );
        }


        if (
            !headers.has(
                "costco-x-authorization"
            ) &&
            token
        ) {
            headers.set(
                "costco-x-authorization",
                "Bearer " + token
            );
        }


        if (
            !headers.has(
                "client-identifier"
            )
        ) {
            headers.set(
                "client-identifier",
                clientIdentifier
            );
        }


        if (
            !headers.has(
                "costco.env"
            )
        ) {
            headers.set(
                "costco.env",
                "ecom"
            );
        }


        if (
            !headers.has(
                "costco.service"
            )
        ) {
            headers.set(
                "costco.service",
                "restOrders"
            );
        }


        headers.set(
            "content-type",
            "application/json-patch+json"
        );


        for (
            const name of [
                "host",
                "origin",
                "referer",
                "content-length",
                "cookie",
                "sec-fetch-mode",
                "sec-fetch-site",
                "sec-fetch-dest"
            ]
        ) {
            headers.delete(name);
        }


        return headers;
    }


    function captureNative(
        url,
        candidateHeaders
    ) {

        if (!isGraphQL(url)) {
            return;
        }

        state.headers =
            bestHeaders(
                candidateHeaders
            );

        state.ready = true;
    }


    // MARK: Value Helpers

    function parseNumber(value) {

        if (value == null) {
            return null;
        }


        if (
            typeof value === "number"
        ) {
            return Number.isFinite(value)
                ? value
                : null;
        }


        if (
            typeof value !== "string"
        ) {
            return null;
        }


        let cleaned =
            value
                .trim()
                .replace(
                    /[$,\s]/g,
                    ""
                );


        if (!cleaned) {
            return null;
        }


        const parenthesized =
            cleaned.startsWith("(") &&
            cleaned.endsWith(")");


        if (parenthesized) {
            cleaned =
                cleaned.slice(
                    1,
                    -1
                );
        }


        const parsed =
            Number(cleaned);


        if (
            !Number.isFinite(parsed)
        ) {
            return null;
        }


        return parenthesized
            ? -Math.abs(parsed)
            : parsed;
    }


    function itemNumber(item) {

        const value =
            item?.itemNumber ??
            item?.sku ??
            item?.skuNumber ??
            item?.itemId ??
            "";


        return String(
            value || ""
        )
        .trim();
    }


    function itemDescription(item) {

        return String(
            item?.itemDescription ??
            item?.itemDescription01 ??
            item?.productDescription ??
            item?.description ??
            item?.productName ??
            item?.name ??
            ""
        );
    }


    function itemQuantity(item) {

        const candidates = [
            item?.quantity,
            item?.qty,
            item?.orderedQuantity,
            item?.itemQuantity,
            item?.orderQuantity
        ];


        for (
            const value
            of candidates
        ) {

            const number =
                parseNumber(value);


            if (
                number != null &&
                number > 0
            ) {
                return number;
            }
        }


        return 1;
    }


    function itemIsCancelled(item) {

        const statusText =
            [
                item?.status,
                item?.orderStatus,
                item?.lineStatus,
                item?.fulfillmentStatus
            ]
            .filter(Boolean)
            .join(" ")
            .toLowerCase();


        return statusText
            .includes("cancel");
    }


    // MARK: Discount Allocation

    // Costco sometimes provides a discount only at
    // the order level instead of the individual item.
    //
    // Allocate that merchandise discount proportionally
    // across the merchandise lines.
    //
    // Allocation is performed in cents so the final
    // line totals add up exactly to Costco's discount.

    function allocateDiscountCents(
        grossLineCents,
        discountCents
    ) {

        if (
            discountCents <= 0
        ) {
            return grossLineCents
                .map(() => 0);
        }


        const grossTotal =
            grossLineCents.reduce(
                (sum, value) =>
                    sum + value,
                0
            );


        if (
            grossTotal <= 0 ||
            discountCents > grossTotal
        ) {
            return null;
        }


        const shares =
            grossLineCents.map(
                (
                    gross,
                    index
                ) => {

                    const exact =
                        discountCents *
                        (
                            gross /
                            grossTotal
                        );

                    const base =
                        Math.floor(exact);


                    return {
                        index: index,
                        cents: base,
                        remainder:
                            exact - base
                    };
                }
            );


        const alreadyAllocated =
            shares.reduce(
                (sum, share) =>
                    sum +
                    share.cents,
                0
            );


        let remaining =
            discountCents -
            alreadyAllocated;


        const remainderOrder =
            [...shares]
                .sort(
                    (a, b) =>
                        b.remainder -
                        a.remainder
                );


        let pointer = 0;


        while (
            remaining > 0 &&
            remainderOrder.length > 0
        ) {

            remainderOrder[
                pointer %
                remainderOrder.length
            ]
            .cents += 1;

            remaining -= 1;
            pointer += 1;
        }


        const result =
            new Array(
                grossLineCents.length
            )
            .fill(0);


        for (
            const share
            of remainderOrder
        ) {

            result[
                share.index
            ] =
                share.cents;
        }


        return result;
    }


    // MARK: Online Order Detail

    function normalizeGetOrderDetails(
        data
    ) {

        const detail =
            data?.data
                ?.getOrderDetails;


        if (
            !detail ||
            typeof detail !== "object"
        ) {
            return null;
        }


        const orderNumber =
            String(
                detail.orderNumber ??
                detail.orderHeaderId ??
                detail.orderId ??
                ""
            )
            .trim();


        if (!orderNumber) {
            return null;
        }


        const orderDate =
            String(
                detail.orderPlacedDate ??
                detail.orderDate ??
                detail.createDate ??
                ""
            );


        const addresses =
            Array.isArray(
                detail.shipToAddress
            )
            ? detail.shipToAddress
            : [];


        const rawItems = [];

        let missingPricedLine = false;


        for (
            const address
            of addresses
        ) {

            const lineItems =
                Array.isArray(
                    address?.orderLineItems
                )
                ? address.orderLineItems
                : [];


            for (
                const item
                of lineItems
            ) {

                if (
                    itemIsCancelled(item)
                ) {
                    continue;
                }


                const number =
                    itemNumber(item);

                const description =
                    itemDescription(item);

                const quantity =
                    itemQuantity(item);

                const grossUnitPrice =
                    parseNumber(
                        item?.price ??
                        item?.itemPrice ??
                        item?.unitPrice
                    );


                if (
                    !number ||
                    !description ||
                    grossUnitPrice == null ||
                    grossUnitPrice <= 0 ||
                    quantity <= 0
                ) {

                    missingPricedLine = true;
                    continue;
                }


                rawItems.push({
                    itemNumber:
                        number,

                    itemDescription:
                        description,

                    quantity:
                        quantity,

                    grossUnitPrice:
                        grossUnitPrice,

                    warehouseNumber:
                        parseNumber(
                            item?.warehouseNumber
                        )
                });
            }
        }


        if (
            rawItems.length === 0
        ) {
            return null;
        }


        const orderDiscount =
            Math.max(
                0,
                parseNumber(
                    detail.discountAmount
                ) ?? 0
            );


        // Do not guess at a discounted order if Costco
        // returned an active merchandise line without
        // enough information to price that line.

        if (
            orderDiscount > 0 &&
            missingPricedLine
        ) {

            post({
                onlineOrderSkipped: {
                    orderSuffix:
                        orderNumber.slice(-4),

                    reason:
                        "A discounted merchandise line could not be priced."
                }
            });

            return null;
        }


        const grossLineCents =
            rawItems.map(
                item =>
                    Math.round(
                        item.grossUnitPrice *
                        item.quantity *
                        100
                    )
            );


        const grossTotalCents =
            grossLineCents.reduce(
                (sum, value) =>
                    sum + value,
                0
            );


        const discountCents =
            Math.round(
                orderDiscount *
                100
            );


        const allocatedDiscounts =
            allocateDiscountCents(
                grossLineCents,
                discountCents
            );


        if (!allocatedDiscounts) {

            post({
                onlineOrderSkipped: {
                    orderSuffix:
                        orderNumber.slice(-4),

                    reason:
                        "The merchandise discount could not be allocated safely."
                }
            });

            return null;
        }


        const normalizedItems = [];


        for (
            let index = 0;
            index < rawItems.length;
            index++
        ) {

            const item =
                rawItems[index];

            const grossCents =
                grossLineCents[index];

            const lineDiscount =
                allocatedDiscounts[index];

            const netLineCents =
                grossCents -
                lineDiscount;


            if (
                netLineCents <= 0
            ) {
                continue;
            }


            const netLineTotal =
                netLineCents /
                100;


            const effectiveUnitPrice =
                netLineTotal /
                item.quantity;


            normalizedItems.push({
                itemNumber:
                    item.itemNumber,

                itemId:
                    item.itemNumber,

                itemDescription:
                    item.itemDescription,

                itemPrice:
                    effectiveUnitPrice,

                quantity:
                    item.quantity
            });
        }


        if (
            normalizedItems.length === 0
        ) {
            return null;
        }


        let warehouseNumber =
            parseNumber(
                detail.warehouseNumber
            );


        if (
            warehouseNumber == null
        ) {

            for (
                const item
                of rawItems
            ) {

                if (
                    item.warehouseNumber != null
                ) {

                    warehouseNumber =
                        item.warehouseNumber;

                    break;
                }
            }
        }


        if (
            warehouseNumber == null
        ) {
            warehouseNumber = 847;
        }


        return {
            data: {
                getOnlineOrders: [
                    {
                        bcOrders: [
                            {
                                orderNumber:
                                    orderNumber,

                                orderHeaderId:
                                    orderNumber,

                                orderPlacedDate:
                                    orderDate,

                                warehouseNumber:
                                    warehouseNumber,

                                orderLineItems:
                                    normalizedItems
                            }
                        ]
                    }
                ]
            }
        };
    }


    // MARK: Warehouse Response

    function usableReceiptArray(
        data
    ) {

        const direct =
            data?.data
                ?.receipts;


        if (
            Array.isArray(direct)
        ) {
            return direct;
        }


        const counted =
            data?.data
                ?.receiptsWithCounts
                ?.receipts;


        return Array.isArray(counted)
            ? counted
            : null;
    }


    // MARK: Online List Response

    function findBCOrderPages(
        value,
        depth = 0
    ) {

        if (
            value == null ||
            depth > 10
        ) {
            return [];
        }


        let results = [];


        if (
            Array.isArray(value)
        ) {

            for (
                const child
                of value
            ) {

                results.push(
                    ...findBCOrderPages(
                        child,
                        depth + 1
                    )
                );
            }


            return results;
        }


        if (
            typeof value === "object"
        ) {

            if (
                Array.isArray(
                    value.bcOrders
                )
            ) {
                results.push(value);
            }


            for (
                const child
                of Object.values(value)
            ) {

                results.push(
                    ...findBCOrderPages(
                        child,
                        depth + 1
                    )
                );
            }
        }


        return results;
    }


    function usableOnlineOrderPages(
        data
    ) {

        const pages =
            findBCOrderPages(
                data?.data
            );


        return pages.length > 0
            ? pages
            : null;
    }


    function countOnlineOrders(
        pages
    ) {

        if (
            !Array.isArray(pages)
        ) {
            return 0;
        }


        return pages.reduce(
            (
                total,
                page
            ) => {

                const orders =
                    Array.isArray(
                        page?.bcOrders
                    )
                    ? page.bcOrders
                    : [];


                return total +
                    orders.length;
            },
            0
        );
    }


    function collectOnlineSummaries(
        pages
    ) {

        if (!Array.isArray(pages)) {
            return;
        }

        for (const page of pages) {

            const orders =
                Array.isArray(page?.bcOrders)
                ? page.bcOrders
                : [];

            for (const order of orders) {

                const orderNumber =
                    String(
                        order?.orderNumber ?? ""
                    )
                    .trim();

                if (!orderNumber) {
                    continue;
                }

                state.onlineSummaries.set(
                    orderNumber,
                    {
                        orderNumber: orderNumber,
                        orderHeaderId:
                            String(
                                order?.orderHeaderId ?? ""
                            )
                            .trim(),
                        orderPlacedDate:
                            String(
                                order?.orderPlacedDate ?? ""
                            ),
                        orderTotal:
                            order?.orderTotal ?? null,
                        status:
                            String(
                                order?.status ?? ""
                            )
                    }
                );
            }
        }
    }


    // MARK: Costco Response Processing

    function onNativeResponse(
        text,
        status,
        url,
        candidateHeaders
    ) {

        if (!isGraphQL(url)) {
            return;
        }


        if (
            status === 401 ||
            status === 403
        ) {

            error(
                "Your Costco session expired. Sign in again to continue."
            );

            return;
        }


        if (
            status < 200 ||
            status >= 300 ||
            typeof text !== "string"
        ) {
            return;
        }


        let data;


        try {
            data =
                JSON.parse(text);

        } catch (_) {
            return;
        }


        captureNative(
            url,
            candidateHeaders
        );


        const receipts =
            usableReceiptArray(data);


        const onlinePages =
            usableOnlineOrderPages(data);


        if (onlinePages) {
            state.lastOnlinePages =
                onlinePages;

            if (sessionMode === "fullSync") {
                state.onlineListingResponseCount += 1;

                collectOnlineSummaries(
                    onlinePages
                );
            }
        }


        if (
            sessionMode === "warehouseOnly" &&
            !receipts
        ) {
            return;
        }


        const pricedOnlineDetail =
            sessionMode === "fullSync"
            ? normalizeGetOrderDetails(data)
            : null;


        if (pricedOnlineDetail) {

            post({
                onlinePricedPayload:
                    pricedOnlineDetail
            });
        }


        if (receipts) {

            state.warehouseReady =
                true;

            post({
                receiptPayload: {
                    data: {
                        receiptsWithCounts: {
                            receipts:
                                receipts
                        }
                    }
                }
            });


            if (
                isTopFrame &&
                !state.started
            ) {

                progress(
                    "Syncing warehouse receipts..."
                );

                void start(
                    sessionMode ===
                        "warehouseOnly"
                );
            }
        }


        if (
            onlinePages &&
            sessionMode === "fullSync"
        ) {

            const count =
                countOnlineOrders(
                    onlinePages
                );


            if (isTopFrame) {

                progress(
                    `Checking Online Purchases... ${count} order${count === 1 ? "" : "s"} found in this period.`
                );


                if (
                    !state.onlineScanStarted
                ) {

                    state.onlineScanStarted =
                        true;


                    setTimeout(
                        () =>
                            void scanOnlineHistory(),
                        1200
                    );
                }
            }
        }
    }




    // MARK: fetch()

    window.fetch =
        function (...args) {

            let url = "";
            let headers = null;
            let capturedRequest = null;


            try {

                const request =
                    new Request(
                        args[0],
                        args[1]
                    );

                capturedRequest =
                    request;


                url =
                    request.url;

                headers =
                    request.headers;


            } catch (_) {

                url =
                    typeof args[0] ===
                    "string"
                    ? args[0]
                    : (
                        args[0]?.url ||
                        ""
                    );


                headers =
                    args[1]?.headers ||
                    args[0]?.headers ||
                    null;
            }


            const result =
                nativeFetch(
                    ...args
                );


            if (
                isGraphQL(url)
            ) {

                result
                    .then(
                        response =>
                            response
                                .clone()
                                .text()
                                .then(
                                    text => {

                                        onNativeResponse(
                                            text,
                                            response.status,
                                            url,
                                            headers
                                        );
                                    }
                                )
                                .catch(
                                    () => {}
                                )
                    )
                    .catch(
                        () => {}
                    );
            }


            return result;
        };


    // MARK: XMLHttpRequest

    if (
        window.XMLHttpRequest
    ) {

        const originalOpen =
            XMLHttpRequest
                .prototype
                .open;


        const originalSetHeader =
            XMLHttpRequest
                .prototype
                .setRequestHeader;


        const originalSend =
            XMLHttpRequest
                .prototype
                .send;


        XMLHttpRequest
            .prototype
            .open =
            function (
                method,
                url,
                ...rest
            ) {

                this.__costcoURL =
                    url;

                this.__costcoHeaders =
                    {};


                return originalOpen.call(
                    this,
                    method,
                    url,
                    ...rest
                );
            };


        XMLHttpRequest
            .prototype
            .setRequestHeader =
            function (
                key,
                value
            ) {

                if (
                    this.__costcoHeaders
                ) {

                    this.__costcoHeaders[
                        key
                    ] =
                        value;
                }


                return originalSetHeader.call(
                    this,
                    key,
                    value
                );
            };


        XMLHttpRequest
            .prototype
            .send =
            function (body) {

                if (
                    isGraphQL(
                        this.__costcoURL
                    )
                ) {

                    this.addEventListener(
                        "loadend",
                        () => {

                            try {

                                const responseText =
                                    this.responseType ===
                                    "json"

                                    ? JSON.stringify(
                                        this.response
                                    )

                                    : this.responseText;


                                onNativeResponse(
                                    responseText,
                                    this.status,
                                    this.__costcoURL,
                                    this.__costcoHeaders
                                );


                            } catch (_) {}
                        },
                        {
                            once: true
                        }
                    );
                }


                return originalSend.call(
                    this,
                    body
                );
            };
    }


    // MARK: Online History

    function historySelect() {

        const selects =
            Array.from(
                document
                    .querySelectorAll(
                        "select"
                    )
            );


        return selects.find(
            select => {

                const text =
                    Array.from(
                        select.options ||
                        []
                    )
                    .map(
                        option =>
                            String(
                                option.textContent ||
                                ""
                            )
                            .trim()
                    )
                    .join(" | ");


                return (
                    /3\s*months?/i
                        .test(text) ||

                    /year/i
                        .test(text) ||

                    /january|february|march|april|may|june|july|august|september|october|november|december/i
                        .test(text)
                );
            }
        ) || null;
    }


    const directDetailTestQuery = `
        query getOrderDetails($orderNumbers: [String]) {
            getOrderDetails(orderNumbers: $orderNumbers) {
                warehouseNumber
                orderNumber: sourceOrderNumber
                orderPlacedDate: orderedDate
                discountAmount
                shipToAddress: orderShipTos {
                    orderLineItems {
                        orderStatus
                        itemNumber
                        itemDescription: sourceItemDescription
                        price: unitPrice
                        quantity: orderedTotalQuantity
                    }
                }
            }
        }
    `;


    async function runIncrementalOnlineDetails(
        summaries
    ) {

        if (
            sessionMode !== "fullSync" ||
            state.incrementalDetailBusy ||
            !Array.isArray(summaries)
        ) {
            return;
        }

        state.incrementalDetailBusy = true;

        let detailFetched = 0;
        let failed = 0;

        try {
            for (
                let index = 0;
                index < summaries.length;
                index++
            ) {

                const summary =
                    summaries[index];

                const orderNumber =
                    String(
                        summary?.orderNumber ?? ""
                    )
                    .trim();

                if (!orderNumber) {
                    failed += 1;
                    continue;
                }

                progress(
                    `Updating ${index + 1} of ${summaries.length}...`
                );

                try {
                    const response =
                        await nativeFetch(
                            endpoint,
                            {
                                method: "POST",
                                credentials: "include",
                                headers:
                                    bestHeaders(
                                        state.headers
                                    ),
                                body:
                                    JSON.stringify({
                                        query:
                                            directDetailTestQuery,
                                        variables: {
                                            orderNumbers: [
                                                orderNumber
                                            ]
                                        }
                                    })
                            }
                        );

                    if (!response.ok) {
                        failed += 1;
                        continue;
                    }

                    detailFetched += 1;

                    const data =
                        await response.json();

                    const normalized =
                        normalizeGetOrderDetails(
                            data
                        );

                    if (!normalized) {
                        failed += 1;
                        continue;
                    }

                    post({
                        onlineIncrementalPayload: {
                            payload: normalized,
                            orderNumber: orderNumber
                        }
                    });

                } catch (_) {
                    failed += 1;
                }
            }

            post({
                onlineIncrementalComplete: {
                    requested:
                        summaries.length,
                    detailFetched:
                        detailFetched,
                    failed:
                        failed
                }
            });

        } finally {
            state.incrementalDetailBusy = false;
        }
    }


    function setSelectValue(
        select,
        value
    ) {

        try {

            const descriptor =
                Object
                    .getOwnPropertyDescriptor(
                        HTMLSelectElement.prototype,
                        "value"
                    );


            descriptor
                ?.set
                ?.call(
                    select,
                    value
                );


        } catch (_) {

            select.value =
                value;
        }


        select.dispatchEvent(
            new Event(
                "input",
                {
                    bubbles: true
                }
            )
        );


        select.dispatchEvent(
            new Event(
                "change",
                {
                    bubbles: true
                }
            )
        );
    }


    async function scanCurrentOnlineRange(
        previousResponseCount,
        allowExistingResponse
    ) {

        if (sessionMode !== "fullSync") {
            return;
        }

        if (
            allowExistingResponse &&
            state.onlineSummaries.size > 0
        ) {
            await wait(350);
            return true;
        }

        for (let attempt = 0; attempt < 48; attempt++) {
            await wait(250);

            if (
                state.onlineListingResponseCount >
                    previousResponseCount
            ) {
                return true;
            }
        }

        return false;
    }


    async function restoreLastThreeMonths(
        select,
        options
    ) {

        const recent =
            options.find(
                option =>
                    /last\s*3\s*months/i
                        .test(
                            option.label
                        )
            );


        if (!recent) {
            return;
        }


        setSelectValue(
            select,
            recent.value
        );


        await wait(1600);
    }


    async function scanOnlineHistory() {

        if (
            sessionMode !== "fullSync" ||
            !isTopFrame ||
            state.onlineScanBusy
        ) {
            return;
        }


        state.onlineScanBusy = true;


        try {

            while (
                state.busy
            ) {
                await wait(750);
            }


            const select =
                historySelect();


            if (!select) {

                error(
                    "Costco's online purchase history could not be read."
                );

                return;
            }


            const options =
                Array.from(
                    select.options ||
                    []
                )
                .map(
                    option => ({
                        value:
                            option.value,

                        label:
                            String(
                                option.textContent ||
                                option.label ||
                                option.value
                            )
                            .trim()
                    })
                )
                .filter(
                    option =>
                        option.value !== ""
                );


            if (
                options.length === 0
            ) {

                error(
                    "No online purchase-history periods were available."
                );

                return;
            }


            progress(
                "Checking Online Purchases..."
            );


            for (
                let index = 0;
                index < options.length;
                index++
            ) {

                const option =
                    options[index];

                const alreadySelected =
                    select.value ===
                        option.value;

                const previousResponseCount =
                    state.onlineListingResponseCount;


                progress(
                    `Online history ${index + 1} of ${options.length}...`
                );


                if (!alreadySelected) {
                    setSelectValue(
                        select,
                        option.value
                    );
                }


                const completed =
                    await scanCurrentOnlineRange(
                        previousResponseCount,
                        alreadySelected
                    );

                if (!completed) {
                    throw new Error(
                        "Online history period did not load."
                    );
                }
            }


            await restoreLastThreeMonths(
                select,
                options
            );


            post({
                onlineListingScanComplete: {
                    ranges:
                        options.length,

                    summaries:
                        Array.from(
                            state.onlineSummaries.values()
                        )
                        .sort(
                            (a, b) =>
                                String(b.orderPlacedDate)
                                .localeCompare(
                                    String(a.orderPlacedDate)
                                )
                        )
                }
            });


        } catch (exception) {

            error(
                "Online sync could not be completed."
            );


        } finally {

            state.onlineScanBusy = false;
        }
    }


    // MARK: Warehouse Queries

    const itemFields =
        "itemNumber itemDescription01 unit amount taxFlag";


    const baseFields =
        `warehouseName transactionDateTime transactionBarcode transactionType total totalItemCount itemArray { ${itemFields} }`;


    const queries = [

        {
            name:
                "receipts",

            query:
                `query receipts(
                    $startDate: String!,
                    $endDate: String!
                ) {
                    receipts(
                        startDate: $startDate,
                        endDate: $endDate
                    ) {
                        ${baseFields}
                    }
                }`
        },

        {
            name:
                "receiptsWithCounts",

            query:
                `query receiptsWithCounts(
                    $startDate: String!,
                    $endDate: String!,
                    $documentType: String!,
                    $documentSubType: String!
                ) {
                    receiptsWithCounts(
                        startDate: $startDate,
                        endDate: $endDate,
                        documentType: $documentType,
                        documentSubType: $documentSubType
                    ) {
                        receipts {
                            ${baseFields}
                        }
                    }
                }`
        }
    ];


    async function requestPeriod(
        startDate,
        endDate,
        variant
    ) {

        const variables = {
            startDate:
                startDate,

            endDate:
                endDate
        };


        if (
            variant.name ===
            "receiptsWithCounts"
        ) {

            variables.documentType =
                "all";

            variables.documentSubType =
                "all";
        }


        const response =
            await nativeFetch(
                endpoint,
                {
                    method:
                        "POST",

                    credentials:
                        "include",

                    headers:
                        bestHeaders(
                            state.headers
                        ),

                    body:
                        JSON.stringify({
                            query:
                                variant.query,

                            variables:
                                variables
                        })
                }
            );


        if (
            response.status === 401 ||
            response.status === 403
        ) {

            throw new Error(
                "Authentication expired."
            );
        }


        if (!response.ok) {

            throw new Error(
                "HTTP " +
                response.status
            );
        }


        const data =
            await response.json();


        if (
            data.errors?.length
        ) {

            throw new Error(
                "Costco returned an error."
            );
        }


        const list =
            variant.name === "receipts"

            ? data?.data
                ?.receipts

            : data?.data
                ?.receiptsWithCounts
                ?.receipts;


        if (
            !Array.isArray(list)
        ) {

            throw new Error(
                "No receipts were returned."
            );
        }


        // Protect previously imported good data from
        // being replaced by summary-only responses.

        if (
            list.some(
                receipt =>
                    Number(
                        receipt.totalItemCount ||
                        0
                    ) > 0 &&
                    (
                        !Array.isArray(
                            receipt.itemArray
                        ) ||
                        receipt.itemArray.length ===
                            0
                    )
            )
        ) {

            throw new Error(
                "Costco returned receipt summaries without item details."
            );
        }


        // Likewise, don't replace working data if Costco
        // returns items without their actual prices.

        if (
            list.some(
                receipt =>
                    Array.isArray(
                        receipt.itemArray
                    ) &&
                    receipt.itemArray.length > 0 &&
                    receipt.itemArray.every(
                        item =>
                            item.amount == null
                    )
            )
        ) {

            throw new Error(
                "Costco returned receipt items without prices."
            );
        }


        return list;
    }


    // MARK: Date Helpers

    function dateUTC(
        year,
        month,
        day
    ) {

        return new Date(
            Date.UTC(
                year,
                month,
                day
            )
        );
    }


    function dateString(date) {

        return `${
            String(
                date.getUTCMonth() + 1
            )
            .padStart(
                2,
                "0"
            )
        }/${
            String(
                date.getUTCDate()
            )
            .padStart(
                2,
                "0"
            )
        }/${
            date.getUTCFullYear()
        }`;
    }


    function plusDays(
        date,
        count
    ) {

        const result =
            new Date(date);


        result.setUTCDate(
            result.getUTCDate() +
            count
        );


        return result;
    }


    function plusMonthsClamped(
        date,
        count
    ) {

        const target =
            dateUTC(
                date.getUTCFullYear(),
                date.getUTCMonth() +
                    count,
                1
            );


        const finalDay =
            dateUTC(
                target.getUTCFullYear(),
                target.getUTCMonth() + 1,
                0
            )
            .getUTCDate();


        target.setUTCDate(
            Math.min(
                date.getUTCDate(),
                finalDay
            )
        );


        return target;
    }


    function periodsForTwoYears(
        today
    ) {

        const newest =
            dateUTC(
                today.getUTCFullYear(),
                today.getUTCMonth(),
                today.getUTCDate()
            );


        let first =
            dateUTC(
                newest.getUTCFullYear() -
                    2,
                newest.getUTCMonth(),
                newest.getUTCDate()
            );


        const periods = [];


        while (
            first <= newest
        ) {

            let end =
                plusDays(
                    plusMonthsClamped(
                        first,
                        6
                    ),
                    -1
                );


            if (
                end > newest
            ) {
                end = newest;
            }


            periods.push({
                start:
                    dateString(first),

                end:
                    dateString(end)
            });


            first =
                plusDays(
                    end,
                    1
                );
        }


        return periods;
    }


    // MARK: Warehouse Sync

    async function start(
        requireWarehouseReady = false
    ) {

        if (
            state.busy
        ) {
            return "already running";
        }


        if (
            !state.ready ||
            (
                requireWarehouseReady &&
                !state.warehouseReady
            )
        ) {

            progress(
                "Open Warehouse Purchases below to continue."
            );

            if (requireWarehouseReady) {
                post({
                    warehouseSyncWaiting: true
                });
            }

            return "waiting";
        }


        state.started = true;
        state.busy = true;


        const periods =
            periodsForTwoYears(
                new Date()
            );


        let totalRows = 0;
        let failed = 0;


        const uniqueBarcodes =
            new Set();


        try {

            for (
                let index = 0;
                index < periods.length;
                index++
            ) {

                const period =
                    periods[index];


                progress(
                    `Syncing warehouse receipts ${index + 1} of ${periods.length}...`
                );


                let list = null;
                let lastProblem = "";


                for (
                    const variant
                    of queries
                ) {

                    try {

                        list =
                            await requestPeriod(
                                period.start,
                                period.end,
                                variant
                            );

                        break;


                    } catch (exception) {

                        lastProblem =
                            String(
                                exception?.message ||
                                exception
                            );
                    }
                }


                if (!list) {

                    failed += 1;

                    if (
                        /Authentication/i
                            .test(
                                lastProblem
                            )
                    ) {
                        break;
                    }

                    continue;
                }


                const fresh =
                    list.filter(
                        receipt => {

                            const key =
                                String(
                                    receipt.transactionBarcode ||
                                    [
                                        receipt.transactionDateTime,
                                        receipt.warehouseName,
                                        receipt.total
                                    ]
                                    .join("-")
                                );


                            if (
                                uniqueBarcodes
                                    .has(key)
                            ) {
                                return false;
                            }


                            uniqueBarcodes
                                .add(key);


                            return true;
                        }
                    );


                totalRows +=
                    fresh.length;


                if (
                    fresh.length > 0
                ) {

                    post({
                        receiptPayload: {
                            data: {
                                receiptsWithCounts: {
                                    receipts:
                                        fresh
                                }
                            }
                        }
                    });
                }


                if (
                    index <
                    periods.length - 1
                ) {

                    await wait(450);
                }
            }


            post({
                syncComplete: {
                    periods:
                        periods.length,

                    failed:
                        failed,

                    receipts:
                        totalRows
                }
            });


        } catch (_) {

            error(
                "Warehouse receipts could not be synced."
            );


        } finally {

            state.busy = false;
        }


        return "finished";
    }


    window.__costcoBulkSync = {
        start:
            start,

        scanOnlineHistory:
            scanOnlineHistory,

        runIncrementalOnlineDetails:
            runIncrementalOnlineDetails
    };


    if (isTopFrame) {

        progress(
            "Open Online and Warehouse below to refresh your Costco purchases."
        );
    }


    return "Costco purchase sync installed";

})();
"""#
    }


    // MARK: WKWebView

    func makeUIView(
        context: Context
    ) -> WKWebView {

        let configuration =
            WKWebViewConfiguration()


        configuration
            .defaultWebpagePreferences
            .allowsContentJavaScript =
                true


        configuration
            .userContentController
            .add(
                context.coordinator,
                name: "costcoSync"
            )


        configuration
            .userContentController
            .addUserScript(
                WKUserScript(
                    source:
                        bulkJavaScript,

                    injectionTime:
                        .atDocumentStart,

                    forMainFrameOnly:
                        false,

                    in:
                        .page
                )
            )


        let webView =
            WKWebView(
                frame: .zero,
                configuration:
                    configuration
            )


        webView.navigationDelegate =
            context.coordinator


        context.coordinator.lastTrigger =
            syncTrigger

        context.coordinator.lastOnlineDetailPlanTrigger =
            onlineDetailPlanTrigger

        webView.load(
            URLRequest(
                url:
                    URL(
                        string:
                            "https://www.costco.com/LogonForm"
                    )!
            )
        )


        return webView
    }


    func updateUIView(
        _ webView: WKWebView,
        context: Context
    ) {

        context.coordinator.onMessage =
            onMessage


        if (
            syncTrigger !=
                context.coordinator.lastTrigger
        ) {

            context.coordinator.lastTrigger =
                syncTrigger

            webView.evaluateJavaScript(
                "void window.__costcoBulkSync?.start();"
            )
        }


        if (
            onlineDetailPlanTrigger !=
                context.coordinator.lastOnlineDetailPlanTrigger
        ) {

            context.coordinator.lastOnlineDetailPlanTrigger =
                onlineDetailPlanTrigger

            let script =
                "void window.__costcoBulkSync?.runIncrementalOnlineDetails(\(onlineDetailPlan));"

            webView.evaluateJavaScript(
                script
            )
        }


    }


    func makeCoordinator()
        -> Coordinator {

        Coordinator(
            onMessage:
                onMessage
        )
    }


    final class Coordinator:
        NSObject,
        WKNavigationDelegate,
        WKScriptMessageHandler {

        var lastTrigger = 0

        var lastOnlineDetailPlanTrigger = 0

        var onMessage:
            (String) -> Void


        init(
            onMessage:
                @escaping
                (String) -> Void
        ) {

            self.onMessage =
                onMessage
        }


        func userContentController(
            _ userContentController:
                WKUserContentController,
            didReceive message:
                WKScriptMessage
        ) {

            if let payload =
                message.body
                as? String {

                onMessage(payload)
            }
        }
    }
}



// MARK: - Costco Sync Screen

struct CostcoSyncWrapperView: View {

    @Binding
    var isPresented: Bool

    var onComplete:
        () -> Void


    @AppStorage(
        "costco_last_successful_sync"
    )
    private var
        lastSuccessfulSyncTimestamp:
            Double = 0


    @AppStorage(
        "costco_last_warehouse_sync"
    )
    private var
        lastWarehouseSyncTimestamp:
            Double = 0


    @AppStorage(
        "costco_last_online_sync"
    )
    private var
        lastOnlineSyncTimestamp:
            Double = 0


    @State
    private var syncTrigger =
        0


    @State
    private var onlineDetailPlan =
        "[]"


    @State
    private var onlineDetailPlanTrigger =
        0


    @State
    private var currentOnlineSyncPlan:
        OnlineOrderSyncPlan? = nil


    @State
    private var onlineDetailIngestionFailures =
        0


    @State
    private var sessionMode:
        CostcoSyncSessionMode? = nil


    @State
    private var statusMessage =
        ""


    @State
    private var warehouseReceipts =
        0


    @State
    private var onlineOrders =
        0


    @State
    private var itemCount =
        0


    @State
    private var isSyncing =
        false


    @State
    private var onlineSyncStarted =
        false


    @State
    private var warehouseSyncStarted =
        false


    @State
    private var onlineCompletedThisSession =
        false


    @State
    private var warehouseCompletedThisSession =
        false


    @State
    private var warehouseWaitingForPage =
        false


    @State
    private var syncError:
        String? = nil


    var body: some View {

        NavigationView {

            Group {

                if let sessionMode {

                    VStack(
                        spacing: 0
                    ) {

                        sessionHeader(
                            for: sessionMode
                        )


                        CostcoSyncView(
                            syncTrigger:
                                syncTrigger,

                            sessionMode:
                                sessionMode,

                            onlineDetailPlan:
                                onlineDetailPlan,

                            onlineDetailPlanTrigger:
                                onlineDetailPlanTrigger
                        ) {
                            message in

                            handleMessage(
                                message
                            )
                        }
                        .id(sessionMode.rawValue)
                    }


                } else {

                    syncModeChooser
                }
            }
            .navigationTitle(
                "Sync Costco Purchases"
            )
            .navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {

                ToolbarItem(
                    placement:
                        .navigationBarTrailing
                ) {

                    Button(
                        "Done"
                    ) {

                        onComplete()

                        isPresented =
                            false
                    }
                }
            }
            .onAppear {

                refreshCounts()
            }
        }
    }


    // MARK: - Sync Mode

    private var syncModeChooser:
        some View {

        VStack(
            alignment: .leading,
            spacing: 16
        ) {

            Text(
                "Choose what to sync"
            )
            .font(.headline)


            Text(
                "Full Sync refreshes online purchases first, then warehouse receipts."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)


            Button {

                sessionMode =
                    .fullSync

            } label: {

                Label(
                    "Start Full Sync",
                    systemImage:
                        "arrow.triangle.2.circlepath"
                )
                .frame(
                    maxWidth: .infinity
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)


            Button {

                warehouseWaitingForPage =
                    true

                sessionMode =
                    .warehouseOnly

            } label: {

                Label(
                    "Sync Warehouse Only",
                    systemImage:
                        "building.2"
                )
                .frame(
                    maxWidth: .infinity
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.large)


            Spacer()
        }
        .padding(20)
    }


    @ViewBuilder
    private func sessionHeader(
        for mode: CostcoSyncSessionMode
    ) -> some View {

        switch mode {

        case .fullSync:
            syncGuide

        case .warehouseOnly:
            VStack(
                alignment: .leading,
                spacing: 6
            ) {

                if warehouseCompletedThisSession {

                    Label(
                        "Warehouse Receipts Synced",
                        systemImage:
                            "checkmark.circle.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(.green)


                } else if isSyncing {

                    HStack(spacing: 10) {
                        ProgressView()
                        Text(
                            "Syncing Warehouse Receipts…"
                        )
                        .font(.headline)
                    }


                } else {

                    Text(
                        "Warehouse Only"
                    )
                    .font(.headline)


                    Text(
                        warehouseWaitingForPage
                        ? "Open Warehouse Purchases below to continue. Online purchases will not be synced in this mode."
                        : "Preparing warehouse receipt sync…"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .background(
                Color(
                    UIColor.secondarySystemBackground
                )
            )
        }
    }


    // MARK: - Guided Sync UI

    private var syncGuide:
        some View {

        VStack(
            alignment:
                .leading,
            spacing: 14
        ) {

            mainStatus


            Divider()


            stepOneRow


            stepTwoRow


            if showFinishSyncButton {

                Button {

                    startWarehouseSync()

                } label: {

                    HStack {

                        Spacer()


                        Image(
                            systemName:
                                "arrow.right.circle.fill"
                        )


                        Text(
                            "Finish Sync"
                        )
                        .fontWeight(
                            .semibold
                        )


                        Spacer()
                    }
                }
                .buttonStyle(
                    .borderedProminent
                )
                .controlSize(
                    .large
                )
                .disabled(
                    isSyncing
                )
            }


            if let syncError {

                Label(
                    syncError,
                    systemImage:
                        "exclamationmark.triangle.fill"
                )
                .font(
                    .caption
                )
                .foregroundStyle(
                    .red
                )
                .padding(
                    .top,
                    2
                )
            }
        }
        .padding(14)
        .frame(
            maxWidth:
                .infinity,
            alignment:
                .leading
        )
        .background(
            Color(
                UIColor
                    .secondarySystemBackground
            )
        )
    }


    // MARK: - Main Status

    @ViewBuilder
    private var mainStatus:
        some View {

        if (
            onlineCompletedThisSession &&
            warehouseCompletedThisSession
        ) {

            HStack(
                spacing: 10
            ) {

                Image(
                    systemName:
                        "checkmark.circle.fill"
                )
                .font(
                    .title2
                )
                .foregroundStyle(
                    .green
                )


                VStack(
                    alignment:
                        .leading,
                    spacing: 3
                ) {

                    Text(
                        "All Purchases Up to Date"
                    )
                    .font(
                        .headline
                    )


                    Text(
                        "\(warehouseReceipts) warehouse receipts • \(onlineOrders) online orders • \(itemCount) items"
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )


                    if let lastSyncText {

                        Text(
                            lastSyncText
                        )
                        .font(
                            .caption2
                        )
                        .foregroundStyle(
                            .secondary
                        )
                    }
                }
            }


        } else if (
            warehouseSyncStarted &&
            isSyncing
        ) {

            HStack(
                spacing: 12
            ) {

                ProgressView()


                VStack(
                    alignment:
                        .leading,
                    spacing: 3
                ) {

                    Text(
                        "Finishing Sync…"
                    )
                    .font(
                        .headline
                    )


                    Text(
                        "No action needed. Keep this screen open."
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
            }


        } else if (
            onlineCompletedThisSession
        ) {

            VStack(
                alignment:
                    .leading,
                spacing: 4
            ) {

                Text(
                    "Online Purchases Synced"
                )
                .font(
                    .headline
                )


                Text(
                    "One step left. Tap Finish Sync below to refresh your warehouse receipts."
                )
                .font(
                    .caption
                )
                .foregroundStyle(
                    .secondary
                )
            }


        } else if (
            onlineSyncStarted &&
            isSyncing
        ) {

            HStack(
                spacing: 12
            ) {

                ProgressView()


                VStack(
                    alignment:
                        .leading,
                    spacing: 3
                ) {

                    Text(
                        "Syncing Online Purchases…"
                    )
                    .font(
                        .headline
                    )


                    Text(
                        statusMessage.isEmpty
                        ? "No action needed. Keep this screen open while Costco purchase history is scanned."
                        : statusMessage
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
            }


        } else {

            VStack(
                alignment:
                    .leading,
                spacing: 4
            ) {

                Text(
                    "Step 1 of 2 — Online Purchases"
                )
                .font(
                    .headline
                )


                Text(
                    "Sign in to Costco if needed, then tap Account, then Orders & Purchases below. The sync will start automatically with your online purchase history."
                )
                .font(
                    .caption
                )
                .foregroundStyle(
                    .secondary
                )
            }
        }
    }


    // MARK: - Step 1

    private var stepOneRow:
        some View {

        HStack(
            spacing: 12
        ) {

            stepIcon(
                complete:
                    onlineCompletedThisSession,

                active:
                    onlineSyncStarted &&
                    !onlineCompletedThisSession
            )


            VStack(
                alignment:
                    .leading,
                spacing: 2
            ) {

                Text(
                    "1. Online Purchases"
                )
                .fontWeight(
                    .semibold
                )


                if (
                    onlineCompletedThisSession
                ) {

                    Text(
                        "\(onlineOrders) online orders synced"
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )


                } else if (
                    onlineSyncStarted
                ) {

                    Text(
                        "Scanning your Costco online purchase history"
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )


                } else {

                    Text(
                        "Tap Online in Costco below"
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
            }


            Spacer()


            if (
                !onlineSyncStarted &&
                !onlineCompletedThisSession
            ) {

                Image(
                    systemName:
                        "arrow.down"
                )
                .foregroundStyle(
                    .blue
                )
            }
        }
    }


    // MARK: - Step 2

    private var stepTwoRow:
        some View {

        HStack(
            spacing: 12
        ) {

            stepIcon(
                complete:
                    warehouseCompletedThisSession,

                active:
                    warehouseSyncStarted &&
                    !warehouseCompletedThisSession
            )


            VStack(
                alignment:
                    .leading,
                spacing: 2
            ) {

                Text(
                    "2. Warehouse Receipts"
                )
                .fontWeight(
                    .semibold
                )


                if (
                    warehouseCompletedThisSession
                ) {

                    Text(
                        "\(warehouseReceipts) warehouse receipts synced"
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )


                } else if (
                    warehouseSyncStarted &&
                    isSyncing
                ) {

                    Text(
                        "Refreshing warehouse purchase history"
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )


                } else if (
                    onlineCompletedThisSession
                ) {

                    Text(
                        "Ready to finish"
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )


                } else {

                    Text(
                        "Available after Online purchases finish"
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
            }


            Spacer()
        }
    }


    // MARK: - Step Icon

    @ViewBuilder
    private func stepIcon(
        complete: Bool,
        active: Bool
    ) -> some View {

        if complete {

            Image(
                systemName:
                    "checkmark.circle.fill"
            )
            .font(
                .title3
            )
            .foregroundStyle(
                .green
            )


        } else if active {

            ProgressView()
                .frame(
                    width: 22,
                    height: 22
                )


        } else {

            Image(
                systemName:
                    "circle"
            )
            .font(
                .title3
            )
            .foregroundStyle(
                .secondary
            )
        }
    }


    // MARK: - Finish Button

    private var showFinishSyncButton:
        Bool {

        onlineCompletedThisSession &&
        !warehouseCompletedThisSession &&
        !warehouseSyncStarted
    }


    // MARK: - Warehouse Sync

    private func startWarehouseSync() {

        guard
            onlineCompletedThisSession,
            !warehouseCompletedThisSession,
            !isSyncing
        else {
            return
        }


        syncError =
            nil


        warehouseSyncStarted =
            true


        isSyncing =
            true


        syncTrigger +=
            1
    }


    // MARK: - Message Handling

    private func handleMessage(
        _ message: String
    ) {

        guard
            let bytes =
                message.data(
                    using:
                        .utf8
                ),

            let root =
                try?
                    JSONSerialization
                        .jsonObject(
                            with:
                                bytes
                        )
                    as? [
                        String:
                            Any
                    ]
        else {
            return
        }


        // MARK: Progress

        if let progress =
            root[
                "syncProgress"
            ]
            as? String {

            statusMessage =
                progress


            if (
                progress.hasPrefix(
                    "Syncing online"
                ) ||
                progress.hasPrefix(
                    "Checking Online"
                ) ||
                progress.hasPrefix(
                    "Updating "
                ) ||
                progress.hasPrefix(
                    "Online history"
                )
            ) {

                onlineSyncStarted =
                    true


                if (
                    !onlineCompletedThisSession
                ) {

                    isSyncing =
                        true
                }
            }


            if (
                progress.hasPrefix(
                    "Syncing warehouse"
                )
            ) {

                warehouseSyncStarted =
                    true


                warehouseWaitingForPage =
                    false


                if (
                    !warehouseCompletedThisSession
                ) {

                    isSyncing =
                        true
                }
            }
        }


        // MARK: Error

        if let error =
            root[
                "syncError"
            ]
            as? String {

            syncError =
                error


            isSyncing =
                false
        }


        // MARK: Warehouse Payload

        if let payload =
            root[
                "receiptPayload"
            ]
            as? [
                String:
                    Any
            ],

           let data =
            try?
                JSONSerialization
                    .data(
                        withJSONObject:
                            payload
                    ),

           let text =
            String(
                data:
                    data,
                encoding:
                    .utf8
            ) {

            DBManager.shared
                .ingestJSON(
                    text
                )


            refreshCounts()
        }


        // MARK: Online Payload

        if let listing =
            root["onlineListingScanComplete"]
                as? [String: Any],
           let rawSummaries =
            listing["summaries"]
                as? [[String: Any]] {

            var uniqueSummaries:
                [String: OnlineOrderSyncSummary] = [:]

            for rawSummary in rawSummaries {
                if let summary = onlineSyncSummary(
                    from: rawSummary
                ) {
                    uniqueSummaries[summary.orderNumber] =
                        summary
                }
            }

            let summaries =
                uniqueSummaries.values.sorted {
                    $0.orderDate > $1.orderDate
                }

            let plan =
                DBManager.shared.prepareOnlineSync(
                    summaries: summaries
                )

            currentOnlineSyncPlan =
                plan

            onlineDetailIngestionFailures =
                0

            statusMessage =
                "Found \(plan.existing) existing orders. \(plan.candidates.count) orders need refreshing."

            let planPayload =
                plan.candidates.map {
                    [
                        "orderNumber": $0.orderNumber
                    ]
                }

            if let data = try? JSONSerialization.data(
                withJSONObject: planPayload,
                options: []
            ),
               let text = String(
                data: data,
                encoding: .utf8
               ) {

                onlineDetailPlan =
                    text

                onlineDetailPlanTrigger +=
                    1
            } else {
                syncError =
                    "Online purchases could not be prepared for updating."

                isSyncing =
                    false
            }
        }


        if let incremental =
            root["onlineIncrementalPayload"]
                as? [String: Any],
           let payload =
            incremental["payload"]
                as? [String: Any],
           let orderNumber =
            incremental["orderNumber"]
                as? String,
           let summary =
            currentOnlineSyncPlan?.candidates.first(
                where: {
                    $0.orderNumber == orderNumber
                }
            ),
           let data = try? JSONSerialization.data(
                withJSONObject: payload
           ),
           let text = String(
                data: data,
                encoding: .utf8
           ) {

            let inserted =
                DBManager.shared.ingestOnlineJSON(
                    text
                )

            if inserted &&
                DBManager.shared.hasValidOnlineOrder(
                summary.orderNumber
            ) {
                DBManager.shared.recordOnlineDetailSuccess(
                    summary
                )
            } else {
                onlineDetailIngestionFailures +=
                    1
            }

            refreshCounts()
        }


        if let completed =
            root["onlineIncrementalComplete"]
                as? [String: Any] {

            let fetched =
                completed["detailFetched"]
                as? Int ?? 0

            let fetchFailures =
                completed["failed"]
                as? Int ?? 0

            let totalFailures =
                fetchFailures +
                onlineDetailIngestionFailures

            finishIncrementalOnlineSync(
                detailFetched: fetched,
                failed: totalFailures
            )
        }


        // MARK: Legacy Online Payload

        if sessionMode == .fullSync,
           let payload =
            root[
                "onlinePricedPayload"
            ]
            as? [
                String:
                    Any
            ],

           let data =
            try?
                JSONSerialization
                    .data(
                        withJSONObject:
                            payload
                    ),

           let text =
            String(
                data:
                    data,
                encoding:
                    .utf8
            ) {

            DBManager.shared
                .ingestJSON(
                    text
                )


            refreshCounts()
        }


        // MARK: Online Complete

        if (
            sessionMode == .fullSync &&
            root[
                "onlineHistoryScanComplete"
            ] != nil
        ) {

            onlineSyncStarted =
                true


            onlineCompletedThisSession =
                true


            isSyncing =
                false


            lastOnlineSyncTimestamp =
                Date()
                    .timeIntervalSince1970


            refreshCounts()


            updateCombinedSyncTimestamp()
        }


        // MARK: Warehouse Complete

        if let finished =
            root[
                "syncComplete"
            ]
            as? [
                String:
                    Any
            ] {

            warehouseSyncStarted =
                true


            let failed =
                finished[
                    "failed"
                ]
                as? Int ?? 0


            isSyncing =
                false


            if (
                failed == 0
            ) {

                warehouseCompletedThisSession =
                    true


                lastWarehouseSyncTimestamp =
                    Date()
                        .timeIntervalSince1970


                refreshCounts()


                #if DEBUG
                print(
                    "COSTCO_ADJ_COUNT \(DBManager.shared.getPriceAdjustmentCount())"
                )
                #endif


                updateCombinedSyncTimestamp()


            } else {

                syncError =
                    "Some warehouse receipts could not be refreshed."
            }
        }
    }


    private func onlineSyncSummary(
        from dictionary: [String: Any]
    ) -> OnlineOrderSyncSummary? {
        func text(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else {
                return ""
            }

            if let string = value as? String {
                return string.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }

            return String(describing: value)
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        }

        let orderNumber =
            text(dictionary["orderNumber"])

        guard !orderNumber.isEmpty else {
            return nil
        }

        let orderHeaderId =
            text(dictionary["orderHeaderId"])

        let rawDate =
            text(
                dictionary["orderDate"] ??
                dictionary["orderPlacedDate"]
            )

        let normalizedDate =
            String(rawDate.prefix(10))

        let status =
            text(dictionary["status"])
                .lowercased()

        let total: Double
        if let number =
            dictionary["orderTotal"]
                as? NSNumber {
            total = number.doubleValue
        } else {
            let cleaned =
                text(dictionary["orderTotal"])
                    .replacingOccurrences(
                        of: "$",
                        with: ""
                    )
                    .replacingOccurrences(
                        of: ",",
                        with: ""
                    )

            total = Double(cleaned) ?? 0
        }

        let totalCents =
            Int((total * 100).rounded())

        let safeStatus =
            status.replacingOccurrences(
                of: "|",
                with: "\\|"
            )

        let signature =
            "v1|\(orderNumber)|\(normalizedDate)|\(totalCents)|\(safeStatus)"

        return OnlineOrderSyncSummary(
            orderNumber: orderNumber,
            orderHeaderId: orderHeaderId,
            orderDate: normalizedDate,
            summarySignature: signature
        )
    }


    private func finishIncrementalOnlineSync(
        detailFetched: Int,
        failed: Int
    ) {
        guard let plan = currentOnlineSyncPlan else {
            syncError =
                "Online purchases could not be finalized."
            isSyncing = false
            return
        }

        if failed == 0 {
            DBManager.shared.markOnlineBackfillComplete()

            onlineSyncStarted =
                true

            onlineCompletedThisSession =
                true

            lastOnlineSyncTimestamp =
                Date().timeIntervalSince1970

            statusMessage =
                "Online Purchases Up to Date"

            refreshCounts()
            updateCombinedSyncTimestamp()

        } else {
            syncError =
                "\(failed) online order\(failed == 1 ? "" : "s") could not be refreshed. Try syncing again."
        }

        isSyncing =
            false

        #if DEBUG
        let backfillComplete =
            DBManager.shared.isOnlineBackfillComplete()
            ? 1
            : 0

        print("COSTCO_ONLINE_SYNC listed=\(plan.listed)")
        print("COSTCO_ONLINE_SYNC existing=\(plan.existing)")
        print("COSTCO_ONLINE_SYNC new=\(plan.new)")
        print("COSTCO_ONLINE_SYNC recent=\(plan.recent)")
        print("COSTCO_ONLINE_SYNC changed=\(plan.changed)")
        print("COSTCO_ONLINE_SYNC skipped=\(plan.skipped)")
        print("COSTCO_ONLINE_SYNC detailFetched=\(detailFetched)")
        print("COSTCO_ONLINE_SYNC failed=\(failed)")
        print("COSTCO_ONLINE_SYNC backfillComplete=\(backfillComplete)")
        #endif
    }


    // MARK: - Last Sync

    private var lastSyncText:
        String? {

        guard
            lastSuccessfulSyncTimestamp >
                0
        else {
            return nil
        }


        let date =
            Date(
                timeIntervalSince1970:
                    lastSuccessfulSyncTimestamp
            )


        let calendar =
            Calendar.current


        let timeFormatter =
            DateFormatter()


        timeFormatter.locale =
            Locale.current


        timeFormatter.timeStyle =
            .short


        if (
            calendar.isDateInToday(
                date
            )
        ) {

            return
                "Last synced today at \(timeFormatter.string(from: date))"
        }


        if (
            calendar.isDateInYesterday(
                date
            )
        ) {

            return
                "Last synced yesterday at \(timeFormatter.string(from: date))"
        }


        let formatter =
            DateFormatter()


        formatter.locale =
            Locale.current


        formatter.dateStyle =
            .medium


        formatter.timeStyle =
            .short


        return
            "Last synced \(formatter.string(from: date))"
    }


    // MARK: - Combined Timestamp

    private func updateCombinedSyncTimestamp() {

        guard
            lastWarehouseSyncTimestamp >
                0,
            lastOnlineSyncTimestamp >
                0
        else {
            return
        }


        lastSuccessfulSyncTimestamp =
            min(
                lastWarehouseSyncTimestamp,
                lastOnlineSyncTimestamp
            )
    }


    // MARK: - Counts

    private func refreshCounts() {

        warehouseReceipts =
            DBManager.shared
                .getWarehouseReceiptCount()


        onlineOrders =
            DBManager.shared
                .getOnlineOrderCount()


        itemCount =
            DBManager.shared
                .getPricedItemCount()
    }
}
