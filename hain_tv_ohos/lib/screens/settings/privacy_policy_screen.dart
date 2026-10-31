import 'package:flutter/material.dart';
import 'package:hain_tv/theme.dart';

/// 隐私政策与用户协议页面。
///
/// AppGallery 上架整改（2026-10-31）：应用内需提供可访问的隐私政策与用户协议
/// 全文，并在首启动以弹窗取得用户同意。
///
/// 【重要】本文案为基于应用实际行为的通用表述，**上架前请核对并补充真实的主体
/// 名称与联系方式**（审核要求与实际声明一致）。
/// ⚠️ 本应用**不含任何第三方服务组件**，服务器由用户自行搭建，
///    故文中不应出现「第三方服务器 / 第三方服务提供方」之类表述。
class PrivacyPolicyScreen extends StatefulWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  State<PrivacyPolicyScreen> createState() => _PrivacyPolicyScreenState();
}

class _PrivacyPolicyScreenState extends State<PrivacyPolicyScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: AppBar(
        title: const Text('隐私政策与用户协议'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          tabs: const [Tab(text: '隐私政策'), Tab(text: '用户协议')],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [_PrivacyPolicyTab(), _UserAgreementTab()],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;

  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            body,
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 13,
              height: 1.6,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacyPolicyTab extends StatelessWidget {
  const _PrivacyPolicyTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: const [
        _Section(
          title: '一、我们如何处理信息',
          body:
              '海因影视（HeinPlay）是一款开源影视客户端。本软件为单机播放工具，'
              '不设开发者运营的服务器，也不接入任何第三方服务组件，'
              '不会收集、上传或出售您的任何个人信息。应用与开发者之间不存在用户数据回传。'
              '您可完全离线使用本软件（含播放本机视频文件）。',
        ),
        _Section(
          title: '二、存储在您设备上的信息',
          body:
              '以下信息仅保存在您本机的应用私有存储中，不会上传：\n'
              '1. 您填写的服务器地址、用户名与密码（用于连接您自己搭建的服务器）；\n'
              '2. 播放记录、收藏夹与搜索历史；\n'
              '3. 本地直播源配置、本地视频文件列表、播放器与界面偏好设置。\n'
              '卸载应用或清除应用数据即可全部删除。',
        ),
        _Section(
          title: '三、权限用途',
          body:
              '· INTERNET（网络）：访问您配置的服务器地址、直播源地址与内容数据接口；\n'
              '· GET_NETWORK_INFO（获取网络状态）：判断当前网络类型与可用性，用于连接状态提示；\n'
              '· KEEP_BACKGROUND_RUNNING（后台运行）：在切换到后台时保持播放会话不中断。\n'
              '本软件不申请位置、通讯录、相册、麦克风、摄像头等敏感权限。',
        ),
        _Section(
          title: '四、您自建的服务与您选择的数据接口',
          body:
              '本应用不包含、不集成、也不指向任何由开发者或第三方运营的服务。'
              '当您使用在线功能时，应用只会向「您自行搭建并填写的服务器」发起请求，'
              '以及向您主动填写的外部内容数据接口地址（如豆瓣、Bangumi）发起请求。'
              '这些服务均由您自行选择、自行部署与自行管理，其内容与隐私规则由其自身负责，'
              '开发者不参与、不控制、也不从中获取任何信息。'
              '相关请求仅包含网络层必要的连接信息（目标地址、请求头等）。'
              '您可在「我的 → 服务器管理」中随时停止使用，也可不配置任何服务器直接离线使用。',
        ),
        _Section(
          title: '五、未成年人保护',
          body:
              '本软件为内容播放工具，不针对未成年人收集任何信息。'
              '若您是未成年人的监护人，请监督其在适当范围内使用。',
        ),
        _Section(
          title: '六、您的权利',
          body:
              '由于本软件不收集您的个人信息，您可随时在应用内清除播放记录、收藏、'
              '搜索历史，或通过卸载应用清除全部本地数据。',
        ),
        _Section(
          title: '七、联系我们',
          body: '如对本政策有任何疑问，可通过项目开源仓库的 Issue 反馈。',
        ),
        _Section(
          title: '八、政策更新',
          body:
              '本政策随应用版本更新。若政策发生实质变更，应用会在更新说明中提示。',
        ),
      ],
    );
  }
}

class _UserAgreementTab extends StatelessWidget {
  const _UserAgreementTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: const [
        _Section(
          title: '一、协议说明',
          body:
              '本协议是您与海因影视（HeinPlay）开源项目之间关于使用本软件的使用约定。'
              '安装或使用本软件即表示您已阅读并同意本协议。',
        ),
        _Section(
          title: '二、软件性质',
          body:
              '本软件是开源的影视播放客户端，为内容聚合与播放工具，'
              '自身不存储、不提供、不推送任何影视内容，也不包含任何第三方服务组件。'
              '影视内容与直播频道均由「您自行搭建并配置的服务器」提供，'
              '本机视频文件则完全来自您自己的设备。',
        ),
        _Section(
          title: '三、您的责任',
          body:
              '1. 您应对自行搭建的服务器及其内容的合法性负责；\n'
              '2. 请勿使用本软件从事违反法律法规或侵犯他人权益的活动；\n'
              '3. 请妥善保管您的服务器账号信息，因保管不当造成的后果由您自行承担。',
        ),
        _Section(
          title: '四、知识产权',
          body:
              '本软件源码遵循仓库内声明的开源许可协议。'
              '影视内容、直播频道及相关权利归各自权利人所有，'
              '与本软件及开源项目无关。',
        ),
        _Section(
          title: '五、免责声明',
          body:
              '本软件按「现状」提供，不对内容来源、可用性、播放效果作任何明示或默示保证。'
              '因使用本软件、您自行搭建的服务器或您自行填写的外部数据接口'
              '所产生的任何损失，开源项目维护者不承担赔偿责任。',
        ),
        _Section(
          title: '六、协议变更',
          body: '本协议可能随软件版本更新而调整，变更后将在应用内更新本页面内容。',
        ),
      ],
    );
  }
}
