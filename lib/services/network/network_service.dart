/// 网络服务的统一接口
/// 
/// 聚合 web_search 和 web_fetch 功能
library;

export 'web_search/web_search_service.dart';
export 'web_fetch/web_fetch_service.dart';

import 'web_search/web_search_service.dart';
import 'web_fetch/web_fetch_service.dart';

class NetworkService {
  static final NetworkService _instance = NetworkService._();
  
  NetworkService._();
  
  static NetworkService get instance => _instance;

  WebSearchService get webSearch => WebSearchService.instance;
  WebFetchService get webFetch => WebFetchService.instance;
}
