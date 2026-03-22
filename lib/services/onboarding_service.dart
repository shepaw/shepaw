import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户引导服务
/// 
/// P1: 提供首次使用引导和功能帮助
class OnboardingService {
  static final OnboardingService _instance = OnboardingService._internal();
  factory OnboardingService() => _instance;
  OnboardingService._internal();

  static const String _keyOnboardingCompleted = 'onboarding_completed';
  static const String _keyFeatureIntroShown = 'feature_intro_shown_';

  /// 检查是否已完成引导
  Future<bool> isOnboardingCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyOnboardingCompleted) ?? false;
  }

  /// 标记引导完成
  Future<void> markOnboardingCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyOnboardingCompleted, true);
  }

  /// 检查特定功能介绍是否已显示
  Future<bool> isFeatureIntroShown(String featureId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_keyFeatureIntroShown$featureId') ?? false;
  }

  /// 标记功能介绍已显示
  Future<void> markFeatureIntroShown(String featureId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_keyFeatureIntroShown$featureId', true);
  }

  /// 重置所有引导状态
  Future<void> resetOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  /// 显示首次引导流程
  Future<void> showOnboarding(BuildContext context) async {
    final completed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => const OnboardingScreen(),
        fullscreenDialog: true,
      ),
    );

    if (completed == true) {
      await markOnboardingCompleted();
    }
  }

  /// 显示功能提示
  Future<void> showFeatureTip(
    BuildContext context, {
    required String featureId,
    required String title,
    required String message,
    IconData icon = Icons.lightbulb_outline,
  }) async {
    final shown = await isFeatureIntroShown(featureId);
    if (shown) return;

    if (context.mounted) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          icon: Icon(icon, size: 48, color: Colors.blue),
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () {
                markFeatureIntroShown(featureId);
                Navigator.pop(context);
              },
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }
}

/// 引导页面
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({Key? key}) : super(key: key);

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  final List<OnboardingPage> _pages = [
    OnboardingPage(
      icon: Icons.waving_hand,
      iconColor: Colors.orange,
      title: '欢迎使用 Paw',
      description: 'Paw 是一个统一的 AI 代理管理平台，\n让您可以轻松管理和使用多个 AI 助手。',
    ),
    OnboardingPage(
      icon: Icons.groups,
      iconColor: Colors.blue,
      title: '多 Agent 支持',
      description: '支持接入 Knot Agent、A2A 协议 Agent 和 OpenClaw Agent，\n所有 Agent 都在一个地方管理。',
    ),
    OnboardingPage(
      icon: Icons.chat_bubble_outline,
      iconColor: Colors.green,
      title: 'Channel 对话',
      description: '创建 Channel 与 Agent 对话，\n支持多个 Agent 协作完成任务。',
    ),
    OnboardingPage(
      icon: Icons.sync_alt,
      iconColor: Colors.purple,
      title: 'OpenClaw 双向通信',
      description: 'OpenClaw Agent 可以主动向您发起聊天，\n实现更智能的交互体验。',
    ),
    OnboardingPage(
      icon: Icons.security,
      iconColor: Colors.red,
      title: '完全本地化',
      description: '所有数据都存储在本地，\n无需担心隐私泄露，随时随地使用。',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 顶部跳过按钮
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('跳过'),
              ),
            ),

            // 页面内容
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (page) => setState(() => _currentPage = page),
                itemCount: _pages.length,
                itemBuilder: (context, index) {
                  return _buildPage(_pages[index]);
                },
              ),
            ),

            // 页面指示器
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _pages.length,
                (index) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _currentPage == index ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _currentPage == index
                        ? Theme.of(context).primaryColor
                        : Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),

            // 底部按钮
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                children: [
                  if (_currentPage > 0)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          _pageController.previousPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        },
                        child: const Text('上一步'),
                      ),
                    ),
                  if (_currentPage > 0) const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        if (_currentPage < _pages.length - 1) {
                          _pageController.nextPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        } else {
                          Navigator.pop(context, true);
                        }
                      },
                      child: Text(
                        _currentPage < _pages.length - 1 ? '下一步' : '开始使用',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(OnboardingPage page) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            page.icon,
            size: 120,
            color: page.iconColor,
          ),
          const SizedBox(height: 48),
          Text(
            page.title,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Text(
            page.description,
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// 引导页面数据
class OnboardingPage {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;

  OnboardingPage({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
  });
}
