package app.nonanona

import app.nonanona.feature.receiptimport.AllowedReceiptFields
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.IncomingPhoto
import app.nonanona.feature.receiptimport.ItemAllocation
import app.nonanona.feature.receiptimport.ItemAllocationProblem
import app.nonanona.feature.receiptimport.ItemAllocationResult
import app.nonanona.feature.receiptimport.ItemAllocator
import app.nonanona.feature.receiptimport.ItemExtractor
import app.nonanona.feature.receiptimport.ItemFlag
import app.nonanona.feature.receiptimport.ItemMemberShare
import app.nonanona.feature.receiptimport.ItemPlan
import app.nonanona.feature.receiptimport.ItemPlanLine
import app.nonanona.feature.receiptimport.OcrLine
import app.nonanona.feature.receiptimport.OcrResult
import app.nonanona.feature.receiptimport.ProcessorError
import app.nonanona.feature.receiptimport.ProcessorException
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.ReceiptFlattener
import app.nonanona.feature.receiptimport.ReceiptProcessor
import app.nonanona.feature.receiptimport.ReceiptReadException
import app.nonanona.feature.receiptimport.ReceiptStorageException
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import javax.imageio.ImageIO

/** 품목 나누기 공통 예제(apps/fixtures/items/examples.json). iOS ReceiptImport 테스트가 같은 파일을 읽는다. */
class ReceiptItemsTest {
    @get:Rule val tmp = TemporaryFolder()

    private val dir = File(System.getProperty("user.dir").orEmpty()).resolve("../../fixtures/items").canonicalFile
    private val examples = JSONObject(File(dir, "examples.json").readText())

    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }

    private fun JSONArray.strings() = (0 until length()).map { getString(it) }

    private fun ocr(
        lines: JSONArray,
        width: Int = 1000,
        height: Int = 1000,
    ) = OcrResult(
        width,
        height,
        lines.objects().map {
            OcrLine(
                it.getInt("id"),
                it.getString("text"),
                it.getDouble("x"),
                it.getDouble("y"),
                it.getDouble("width"),
                it.getDouble("height"),
                it.optJSONArray("corners")?.let { points ->
                    (0 until points.length()).flatMap { index ->
                        val point = points.getJSONArray(index)
                        listOf(point.getDouble(0), point.getDouble(1))
                    }
                },
            )
        },
    )

    @Test
    fun sharedExtractionExamples() {
        assertEquals(ItemExtractor.VERSION, examples.getString("extractor"))
        for (e in examples.getJSONArray("extraction").objects()) {
            val name = e.getString("name")
            val result = ItemExtractor.extract(ocr(e.getJSONArray("lines")), e.getLong("receiptTotal"))
            val items = e.getJSONArray("items").objects()
            assertEquals(name, items.map { it.getString("id") }, result.candidates.map { it.id })
            for ((got, want) in result.candidates.zip(items)) {
                assertEquals("$name ${got.id}", want.getString("name"), got.originalName)
                assertEquals("$name ${got.id}", if (want.isNull("amount")) null else want.getLong("amount"), got.amountMinor)
                assertEquals("$name ${got.id}", want.getJSONArray("flags").strings(), got.flags.map { it.wire })
            }
            val summary = e.getJSONArray("summary").objects()
            assertEquals(name, summary.map { it.getString("id") }, result.summary.map { it.id })
            assertEquals(name, summary.map { it.getString("kind") }, result.summary.map { it.kind.wire })
            assertEquals(
                name,
                summary.map { if (it.isNull("amount")) null else it.getLong("amount") },
                result.summary.map { it.amountMinor },
            )
            assertEquals(name, if (e.isNull("ocrTotal")) null else e.getLong("ocrTotal"), result.ocrTotalMinor)
        }
    }

    @Test
    fun sharedRowGeometry() {
        for (scenario in JSONArray(File(dir, "row-geometry.json").readText()).objects()) {
            val name = scenario.getString("name")
            val ocr = ocr(scenario.getJSONArray("lines"), 800, 1200)
            val total = scenario.getLong("receiptTotal")
            val result = ItemExtractor.extract(ocr, total)
            val items = scenario.getJSONArray("items").objects()
            assertEquals(name, items.map { it.getString("id") }, result.candidates.map { it.id })
            for ((got, want) in result.candidates.zip(items)) {
                val ids = want.getJSONArray("sourceLineIDs")
                assertEquals(name, (0 until ids.length()).map(ids::getInt), got.sourceLineIds)
                assertEquals(name, want.getString("name"), got.originalName)
                assertEquals(name, if (want.isNull("amount")) null else want.getLong("amount"), got.amountMinor)
                val flags = want.getJSONArray("flags").strings()
                assertEquals(name, flags, got.flags.map { it.wire })
                if ("amountLinkUncertain" in flags) {
                    val fields = AllowedReceiptFields("2026-11-06", total, "JPY", null)
                    val plan = requireNotNull(ItemPlan.seed(fields, ocr)).setName(got.id, "녹차")
                    val saved = ItemPlan.fromJson(plan.toJson())
                    assertEquals(name, true, saved.line(got.id)?.needsCheck)
                    assertEquals(name, false, saved.markChecked(got.id).line(got.id)?.needsCheck)
                }
            }
        }
    }

    private fun plan(a: JSONObject) =
        ItemPlan(
            ItemExtractor.VERSION,
            a.getString("currency"),
            a.getLong("total"),
            null,
            emptyList(),
            a.getJSONArray("lines").objects().map {
                ItemPlanLine(
                    it.getString("id"),
                    ItemPlanLine.Kind.entries.first { k -> k.wire == it.getString("kind") },
                    emptyList(),
                    "",
                    "",
                    it.getString("id"),
                    ItemPlanLine.NameSource.User,
                    it.getString("amount"),
                    it.getJSONArray("flags").strings().map { f -> ItemFlag.of(f) },
                    it.getBoolean("checked"),
                    it.getBoolean("excluded"),
                    it.getJSONArray("assignees").strings(),
                )
            },
            10,
        )

    /** 결과를 예제의 expect 모양으로 바꾼다. */
    private fun describe(r: ItemAllocationResult): JSONObject {
        fun shares(s: List<ItemMemberShare>) = JSONObject().also { o -> s.forEach { o.put(it.member, it.krw) } }
        val o = JSONObject()
        when (val a = r.allocation) {
            is ItemAllocation.Exact -> {
                o.put("kind", "exact").put("shares", shares(a.shares))
            }

            is ItemAllocation.PairRule -> {
                o.put("kind", "pairRule").put("shares", shares(a.shares))
            }

            is ItemAllocation.Remainder -> {
                o.put("kind", "remainder").put("shares", shares(a.floors)).put("remaining", a.remaining)
            }

            null -> {
                o.put("kind", "problem")
                when (val p = r.problem!!) {
                    ItemAllocationProblem.NoLines -> o.put("problem", "noLines")
                    ItemAllocationProblem.UnsupportedCurrency -> o.put("problem", "unsupportedCurrency")
                    is ItemAllocationProblem.AmountInvalid -> o.put("problem", "amountInvalid").put("line", p.lineId)
                    is ItemAllocationProblem.NeedsCheck -> o.put("problem", "needsCheck").put("line", p.lineId)
                    is ItemAllocationProblem.Unassigned -> o.put("problem", "unassigned").put("line", p.lineId)
                    is ItemAllocationProblem.TotalMismatch -> o.put("problem", "totalMismatch").put("difference", p.difference)
                    ItemAllocationProblem.KrwMissing -> o.put("problem", "krwMissing")
                    is ItemAllocationProblem.NonPositiveShare -> o.put("problem", "nonPositiveShare").put("member", p.member)
                    ItemAllocationProblem.TooLarge -> o.put("problem", "tooLarge")
                }
            }
        }
        return o
    }

    @Test
    fun sharedAllocationExamples() {
        for (a in examples.getJSONArray("allocation").objects()) {
            val got =
                describe(
                    ItemAllocator.allocate(
                        plan(a),
                        if (a.isNull("krw")) null else a.getLong("krw"),
                        if (a.isNull("payer")) null else a.getString("payer"),
                        a.getJSONArray("members").strings(),
                    ),
                )
            val want = a.getJSONObject("expect")
            assertEquals(a.getString("name"), want.toMap(), got.toMap())
            if (want.getString("kind") == "exact") {
                val krw = if (a.getString("currency") == "KRW") a.getLong("total") else a.getLong("krw")
                val s = want.getJSONObject("shares")
                assertEquals(a.getString("name"), krw, s.keys().asSequence().sumOf { s.getLong(it) })
            }
        }
    }

    @Test
    fun editsKeepStableIdsAndUserNames() {
        val a = examples.getJSONArray("allocation").objects().first { it.getString("name") == "i02_tax_discount_mismatch" }
        var p = plan(a).copy(lines = plan(a).lines.map { it.copy(nameSource = ItemPlanLine.NameSource.None, name = "") })
        p = p.setName("ocr-4", "녹차")
        p = p.applyTranslations(mapOf("ocr-2" to "주먹밥 연어", "ocr-4" to "다른 번역"), ItemPlanLine.NameSource.OnDevice)
        assertEquals("녹차", p.line("ocr-4")?.name)
        assertEquals("주먹밥 연어", p.line("ocr-2")?.name)
        assertEquals(ItemPlanLine.NameSource.OnDevice, p.line("ocr-2")?.nameSource)

        val (p1, first) = p.addLine(ItemPlanLine.Kind.Adjustment, "할인", "-50")
        val (p2, second) = p1.addLine(ItemPlanLine.Kind.Adjustment, "세금", "51")
        assertEquals("manual-10", first)
        assertEquals("manual-11", second)
        val (p3, third) = p2.removeManual(first).addLine(ItemPlanLine.Kind.Item, "봉투", "3")
        assertEquals("manual-12", third)
        val p4 = p3.removeManual("ocr-2").setExcluded("ocr-2", true)
        assertNotNull(p4.line("ocr-2"))
        assertEquals(listOf("ocr-4", "ocr-6", "manual-11", "manual-12"), p4.activeLines.map { it.id })
        assertNull(ItemPlan.parseAmount("-50", allowNegative = false))
        assertEquals(-50L, ItemPlan.parseAmount("▲５０", allowNegative = true))
        assertEquals(1320L, ItemPlan.parseAmount("1,320", allowNegative = false))
        assertNull(ItemPlan.parseAmount("0", allowNegative = true))
        // 저장 형식을 오가도 같다.
        assertEquals(p4, ItemPlan.fromJson(p4.toJson()))
    }

    private val flattener =
        ReceiptFlattener { original, _ ->
            val source = ImageIO.read(original)
            val image = java.awt.image.BufferedImage(source.width, source.height, java.awt.image.BufferedImage.TYPE_INT_RGB)
            image.createGraphics().apply { drawImage(source, 0, 0, null) }.dispose()
            ByteArrayOutputStream().also { ImageIO.write(image, "png", it) }.toByteArray()
        }

    /** 공통 예제 single_line_rows의 OCR 줄(r01과 같은 글자)을 돌려주는 대역. 실제 ML Kit은 에뮬레이터 E2E에서 확인한다. */
    private val rowsOcr = ocr(examples.getJSONArray("extraction").getJSONObject(0).getJSONArray("lines"))

    private fun confirmedProcessor(store: ReceiptDraftStore): Pair<ReceiptProcessor, String> =
        runBlocking {
            store.create(DraftSource.Share, listOf(IncomingPhoto("png") { File(dir, "receipt-i02.png").inputStream() }))
            val processor = ReceiptProcessor(store, store.list().single(), { rowsOcr }, flattener)
            processor.run()
            val item = processor.snapshot().items.single()
            try {
                processor.itemPlan(item.id)
                fail("확인 전에는 계획이 없다")
            } catch (e: ProcessorException) {
                assertEquals(ProcessorError.WrongState, e.error)
            }
            val proposal = processor.proposal(item.id)
            processor.confirm(item.id, proposal.fields, proposal.suggestedMaskLineIds.toSet())
            processor to item.id
        }

    /** 확인한 영수증의 계획은 초안 폴더에만 쓰고, 다시 열어도 같으며, 늦게 온 옛 입력이 덮지 않는다. 경계 값은 그대로다. */
    @Test
    fun planIsDurableLocalAndOutsideTheBoundary() =
        runBlocking {
            val root = tmp.newFolder()
            val store = ReceiptDraftStore(root)
            val (processor, id) = confirmedProcessor(store)
            val before = processor.outboundReceipts()
            var plan = processor.itemPlan(id)!!
            assertEquals(listOf("ocr-3", "ocr-4"), plan.lines.map { it.id })
            assertEquals(128L + 0, plan.difference) // 외세: 품목 1,280엔, 합계 1,408엔
            plan =
                plan
                    .setAssignee("ocr-3", "host", true)
                    .setName("ocr-3", "오늘의 정식")
                    .addLine(ItemPlanLine.Kind.Adjustment, "소비세", "128")
                    .first
            processor.saveItemPlan(id, plan, 2)
            processor.saveItemPlan(id, plan.setName("ocr-3", "옛 입력"), 1)

            val reopened = ReceiptProcessor(store, store.list().single(), { rowsOcr }, flattener)
            assertEquals(plan, reopened.itemPlan(id))
            try {
                reopened.saveItemPlan(id, plan.copy(receiptTotalMinor = 1))
                fail("합계가 다른 계획은 쓰지 않는다")
            } catch (e: ProcessorException) {
                assertEquals(ProcessorError.InvalidFields, e.error)
            }
            val after = reopened.outboundReceipts()
            assertEquals(before.map { it.receipt }, after.map { it.receipt })
            assertTrue(after.zip(before).all { (a, b) -> a.artifactPng.contentEquals(b.artifactPng) })
            assertTrue(File(root, "drafts/${store.list().single().id}/items/$id.json").isFile)
        }

    @Test
    fun failedPlanWriteThrowsAndKeepsLastSaved() =
        runBlocking {
            var failing = false
            val store = ReceiptDraftStore(tmp.newFolder(), writeFault = { it.path.contains("/items/") && failing })
            val (processor, id) = confirmedProcessor(store)
            val plan = processor.itemPlan(id)!!.setName("ocr-3", "정식")
            processor.saveItemPlan(id, plan)
            failing = true
            try {
                processor.saveItemPlan(id, plan.setName("ocr-3", "저장 안 됨"))
                fail("쓰기 실패를 숨기지 않는다")
            } catch (_: ReceiptStorageException) {
            }
            assertEquals("정식", processor.itemPlan(id)?.line("ocr-3")?.name)
        }

    /** 저장한 계획이 있는데 읽지 못하면 OCR로 새로 만들지 않고 던진다. 디스크 파일은 그대로이고, 다시 읽으면 같은 계획이 온다. */
    @Test
    fun unreadablePlanIsNotReseededAndRetryLoadsIt() =
        runBlocking {
            var failing = false
            val root = tmp.newFolder()
            val store = ReceiptDraftStore(root, readFault = { it.path.contains("/items/") && failing })
            val (processor, id) = confirmedProcessor(store)
            val plan = processor.itemPlan(id)!!.setName("ocr-3", "정식").setAssignee("ocr-3", "host", true)
            processor.saveItemPlan(id, plan)
            val file = File(root, "drafts/${store.list().single().id}/items/$id.json")
            val saved = file.readBytes()

            failing = true
            for (p in listOf(processor, ReceiptProcessor(store, store.list().single(), { rowsOcr }, flattener))) {
                try {
                    p.itemPlan(id)
                    fail("읽지 못한 계획을 OCR로 새로 만들지 않는다")
                } catch (_: ReceiptReadException) {
                }
            }
            assertTrue(saved.contentEquals(file.readBytes()))
            failing = false
            assertEquals(plan, processor.itemPlan(id))
        }

    /** 풀 수 없는 파일, 확인한 합계·통화와 다른 파일은 ItemPlanInvalid로 던지고 지우거나 덮지 않는다. 파일이 없을 때만 새로 만든다. */
    @Test
    fun invalidPlanFileIsKeptAndOnlyAbsentSeeds() =
        runBlocking {
            val root = tmp.newFolder()
            val store = ReceiptDraftStore(root)
            val (processor, id) = confirmedProcessor(store)
            val file = File(root, "drafts/${store.list().single().id}/items/$id.json")
            val seeded = processor.itemPlan(id)!!
            assertTrue(!file.exists()) // 새로 만든 계획은 쓰지 않는다

            file.parentFile.mkdirs()
            for (bad in listOf("{\"extractor\":", seeded.copy(receiptTotalMinor = seeded.receiptTotalMinor + 1).toJson())) {
                file.writeText(bad)
                try {
                    processor.itemPlan(id)
                    fail("손상되거나 맞지 않는 계획을 열지 않는다")
                } catch (e: ProcessorException) {
                    assertEquals(ProcessorError.ItemPlanInvalid, e.error)
                }
                assertEquals(bad, file.readText())
            }
            file.delete()
            assertEquals(seeded, processor.itemPlan(id))
        }

    /** 늦게 도착한 번역은 그사이 사용자가 적은 이름을 덮지 않고, 원문이 다른 줄(다른 계획)에는 들어가지 않는다. */
    @Test
    fun delayedTranslationKeepsManualEditsAndIdentity() =
        runBlocking {
            val (processor, id) = confirmedProcessor(ReceiptDraftStore(tmp.newFolder()))
            var plan = processor.itemPlan(id)!!
            val requested = plan.lines.filter { it.originalName.isNotEmpty() && it.nameSource != ItemPlanLine.NameSource.User }
            assertTrue(requested.size >= 2)
            val names = requested.associate { it.id to "번역-${it.id}" }
            val originals = requested.associate { it.id to it.originalName } + (requested[1].id to "다른 원문")
            plan = plan.setName(requested[0].id, "직접 적음")
            plan = plan.applyTranslations(names, ItemPlanLine.NameSource.OnDevice, originals)
            assertEquals("직접 적음", plan.line(requested[0].id)?.name)
            assertEquals(ItemPlanLine.NameSource.User, plan.line(requested[0].id)?.nameSource)
            assertEquals("", plan.line(requested[1].id)?.name)
            assertEquals(ItemPlanLine.NameSource.None, plan.line(requested[1].id)?.nameSource)
            requested.drop(2).forEach {
                assertEquals("번역-${it.id}", plan.line(it.id)?.name)
                assertEquals(ItemPlanLine.NameSource.OnDevice, plan.line(it.id)?.nameSource)
            }
        }

    @Test
    fun acceptedRetranslationKeepsAmountCheckAndRejectsSnapshotAfterEdit() =
        runBlocking {
            val (processor, id) = confirmedProcessor(ReceiptDraftStore(tmp.newFolder()))
            val plan = processor.itemPlan(id)!!
            val snapshot = plan.lines.first { it.originalName.isNotEmpty() }
            assertTrue(!snapshot.checked)
            val accepted = plan.acceptRetranslation("오늘의 정식", snapshot)
            val expected = snapshot.copy(name = "오늘의 정식", nameSource = ItemPlanLine.NameSource.User)
            assertEquals(expected, accepted.line(snapshot.id))

            val edited = accepted.setName(snapshot.id, "직접 적은 이름")
            assertEquals(edited, edited.acceptRetranslation("오래된 제안", expected))
        }
}

private fun JSONObject.toMap(): Map<String, Any?> =
    keys().asSequence().associateWith { k ->
        when (val v = get(k)) {
            is JSONObject -> v.toMap()
            is Number -> v.toLong()
            else -> v
        }
    }
