import Foundation

public struct HotwordEntry: Sendable, Equatable {
    public let canonical: String
    public let aliases: [String]

    public init(_ canonical: String, aliases: [String] = []) {
        self.canonical = canonical
        self.aliases = aliases
    }
}

public struct HotwordDomain: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let entries: [HotwordEntry]

    public var words: [String] { entries.map(\.canonical) }

    public init(id: String, name: String, summary: String, entries: [HotwordEntry]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.entries = entries
    }
}

public enum HotwordDomainCatalog {
    private static func e(_ canonical: String, _ aliases: [String] = []) -> HotwordEntry {
        HotwordEntry(canonical, aliases: aliases)
    }

    public static let all: [HotwordDomain] = [
        .init(
            id: "vibe_coding",
            name: "Vibe Coding",
            summary: "代码、Agent、框架、数据库、云服务与英文专名",
            entries: [
                e("Cursor"), e("Claude"), e("ChatGPT", ["Chat GPT"]),
                e("OpenAI", ["Open AI"]),
                e("Anthropic"), e("Windsurf", ["Windsurf"]),
                e("VS Code", ["VSCode", "Visual Studio Code"]),
                e("Xcode", ["X Code"]), e("SwiftUI", ["Swift UI"]),
                e("TypeScript", ["Type Script"]), e("JavaScript", ["Java Script"]),
                e("Next.js", ["NextJS", "Next JS"]), e("Node.js", ["NodeJS", "Node JS"]),
                e("React"), e("Vue"), e("Svelte"),
                e("PyTorch", ["Py Torch"]), e("TensorFlow", ["Tensor Flow"]),
                e("GitHub", ["Git Hub"]), e("GitLab", ["Git Lab"]),
                e("Docker"), e("Kubernetes", ["K8s"]),
                e("PostgreSQL", ["Postgres", "Postgre SQL"]),
                e("MySQL", ["My SQL"]), e("Redis"), e("Supabase"),
                e("LangChain", ["Lang Chain"]), e("LangGraph", ["Lang Graph"]),
                e("Webhook", ["Web Hook"]), e("OAuth"), e("JWT"),
                e("RESTful"), e("GraphQL", ["Graph QL"]),
                e("RAG"), e("SDK"), e("API"), e("CLI"), e("MCP"), e("LLM")
            ]
        ),
        .init(
            id: "ai_speech",
            name: "AI / 语音",
            summary: "ASR、TTS、VAD、推理、量化与多模态模型术语",
            entries: [
                e("ASR"), e("TTS"), e("VAD"), e("ITN"), e("NER"),
                e("Whisper"), e("sherpa-onnx", ["Sherpa ONNX", "SherpaOnnx"]),
                e("ONNX Runtime", ["ONNXRuntime"]), e("ggml"), e("llama.cpp", ["llama cpp"]),
                e("MiniCPM"), e("Qwen"), e("DeepSeek"), e("Gemma"), e("Llama"),
                e("MoE"), e("Transformer"), e("attention"), e("embedding"),
                e("tokenizer"), e("checkpoint"), e("inference"), e("throughput"),
                e("latency"), e("beam search"), e("greedy search"),
                e("quantization"), e("LoRA"), e("QLoRA"), e("RLHF"), e("PPO"),
                e("GRPO"), e("distillation"), e("diffusion"), e("CLIP"),
                e("VLM"), e("multimodal"), e("speaker diarization"),
                e("endpointing"), e("streaming"), e("prompt"), e("context window")
            ]
        ),
        .init(
            id: "education",
            name: "教育",
            summary: "课程、考试、教研、论文与教学管理术语",
            entries: [
                e("课程大纲"), e("教学设计"), e("教案"), e("板书"), e("知识点"),
                e("随堂测验"), e("单元测试"), e("期中考试"), e("期末考试"), e("阅卷"),
                e("作业反馈"), e("课堂观察"), e("启发式教学"), e("翻转课堂"), e("项目制学习"),
                e("同伴互评"), e("学术诚信"), e("论文答辩"), e("文献综述"), e("研究方法"),
                e("实验报告"), e("开题报告"), e("盲审"), e("学分绩点"), e("毕业设计")
            ]
        ),
        .init(
            id: "legal",
            name: "法律",
            summary: "法条、合同、诉讼、合规与公司治理术语",
            entries: [
                e("民法典"), e("刑法"), e("行政诉讼"), e("仲裁"), e("合同纠纷"),
                e("知识产权"), e("商标权"), e("著作权"), e("专利权"), e("起诉状"),
                e("答辩状"), e("举证责任"), e("保全"), e("违约责任"), e("不可抗力"),
                e("尽职调查"), e("合规审查"), e("法定代表人"), e("实际控制人"), e("保密协议"),
                e("竞业限制"), e("补充协议"), e("管辖权"), e("强制执行"), e("律师函")
            ]
        ),
        .init(
            id: "medical",
            name: "医疗",
            summary: "门诊、检查、处方、影像与医学专名",
            entries: [
                e("门诊"), e("住院"), e("会诊"), e("病历"), e("主诉"), e("既往史"),
                e("体格检查"), e("诊断意见"), e("处方"), e("复诊"), e("并发症"),
                e("高血压"), e("糖尿病"), e("冠心病"), e("脑梗"), e("肺结节"),
                e("CT"), e("MRI"), e("ICU"), e("PCR"), e("心电图"),
                e("磁共振"), e("超声"), e("血常规"), e("肝功能"), e("肾功能"),
                e("阿司匹林"), e("布洛芬"), e("头孢"), e("胰岛素")
            ]
        ),
        .init(
            id: "finance",
            name: "金融",
            summary: "财务、投研、证券、估值与经营分析术语",
            entries: [
                e("A股"), e("港股"), e("纳斯达克"), e("标普500"), e("上证指数"),
                e("现金流"), e("资产负债表"), e("利润表"), e("毛利率"), e("净利率"),
                e("市盈率"), e("市净率"), e("自由现金流"), e("EBITDA"), e("ROI"),
                e("IRR"), e("GMV"), e("ARPU"), e("回撤"), e("波动率"),
                e("贝塔"), e("久期"), e("信用利差"), e("尽职调查"), e("估值模型")
            ]
        ),
        .init(
            id: "shopping",
            name: "购物",
            summary: "电商、订单、物流、商品属性与售后词汇",
            entries: [
                e("预售"), e("现货"), e("满减"), e("优惠券"), e("包邮"),
                e("七天无理由"), e("退货退款"), e("换货"), e("运费险"), e("发货"),
                e("签收"), e("物流单号"), e("补差价"), e("尺码"), e("色号"),
                e("库存"), e("缺货"), e("催发货"), e("售后"), e("客服"),
                e("官方旗舰店"), e("到手价"), e("定金"), e("尾款"), e("拼单")
            ]
        ),
        .init(
            id: "customer_service",
            name: "客服",
            summary: "工单、回访、核验、升级处理与服务话术",
            entries: [
                e("工单"), e("服务单"), e("升级处理"), e("回访"), e("问题复现"),
                e("故障排查"), e("满意度"), e("处理时效"), e("退款申请"), e("物流异常"),
                e("账号核验"), e("转人工"), e("售后专员"), e("优先级"), e("闭环"),
                e("质检"), e("话术"), e("误触发"), e("二线支持"), e("升级专员"),
                e("场景复盘"), e("补偿方案"), e("已受理"), e("待跟进")
            ]
        ),
        .init(
            id: "marketing",
            name: "市场营销",
            summary: "投放、增长、内容运营与数据指标术语",
            entries: [
                e("ROI"), e("ROAS"), e("CPC"), e("CPM"), e("CTR"),
                e("CVR"), e("SEO"), e("SEM"), e("A/B 测试", ["AB 测试", "A B 测试"]),
                e("私域"), e("公域"), e("转化漏斗"), e("投放素材"), e("种草"),
                e("拉新"), e("促活"), e("留存"), e("复购"), e("人群包"),
                e("UV"), e("PV"), e("DAU"), e("MAU"), e("KOL"), e("KPI")
            ]
        ),
        .init(
            id: "hr_recruiting",
            name: "招聘 HR",
            summary: "招聘、绩效、组织、面试与人事流程术语",
            entries: [
                e("JD"), e("HC"), e("offer"), e("ATS"), e("OKR"), e("KPI"),
                e("人才盘点"), e("胜任力模型"), e("绩效校准"), e("背调"), e("入职"),
                e("转正"), e("离职交接"), e("薪酬带宽"), e("面试官"), e("招聘漏斗"),
                e("候选人"), e("用人经理"), e("雇主品牌"), e("校招"), e("社招"),
                e("人才地图"), e("组织诊断"), e("编制")
            ]
        ),
        .init(
            id: "real_estate",
            name: "房产",
            summary: "买房、租房、贷款、交易与中介术语",
            entries: [
                e("网签"), e("备案"), e("首付"), e("公积金"), e("商贷"),
                e("等额本息"), e("等额本金"), e("带看"), e("学区房"), e("得房率"),
                e("容积率"), e("套内面积"), e("建筑面积"), e("新房"), e("二手房"),
                e("过户"), e("契税"), e("满五唯一"), e("中介费"), e("房本"),
                e("租约"), e("押一付三"), e("拎包入住"), e("验房")
            ]
        ),
        .init(
            id: "gaming",
            name: "游戏",
            summary: "平台、品类、玩法、系统与发行术语",
            entries: [
                e("Steam"), e("Epic"), e("PlayStation"), e("Xbox"),
                e("Nintendo Switch", ["Switch"]), e("RPG"), e("FPS"), e("MOBA"),
                e("MMORPG"), e("roguelike"), e("DLC"), e("battle pass", ["Battle Pass"]),
                e("matchmaking"), e("ranked"), e("patch notes"), e("gacha"),
                e("公会"), e("副本"), e("赛季"), e("天梯"), e("数值策划"),
                e("买量"), e("发行"), e("留存"), e("新手引导")
            ]
        ),
        .init(
            id: "hardware_manufacturing",
            name: "硬件 / 制造",
            summary: "电子、工厂、供应链、研发与生产术语",
            entries: [
                e("BOM"), e("SOP"), e("ERP"), e("MES"), e("PLM"),
                e("PCB"), e("SMT"), e("CNC"), e("MCU"), e("SoC", ["SOC"]),
                e("GPIO"), e("I2C"), e("SPI"), e("UART"), e("示波器"),
                e("逻辑分析仪"), e("公差"), e("良率"), e("工装夹具"), e("首件"),
                e("试产"), e("量产"), e("供应商"), e("交期"), e("ECO"), e("ECN")
            ]
        )
    ]

    public static func byID(_ id: String) -> HotwordDomain? {
        all.first { $0.id == id }
    }

    public static func words(for ids: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for id in ids {
            guard let domain = byID(id) else { continue }
            for word in domain.words where seen.insert(word).inserted {
                out.append(word)
            }
        }
        return out
    }

    public static func aliasMap(for ids: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for id in ids {
            guard let domain = byID(id) else { continue }
            for entry in domain.entries {
                for alias in entry.aliases where out[alias] == nil {
                    out[alias] = entry.canonical
                }
            }
        }
        return out
    }
}
