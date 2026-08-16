class Config {
  // Ubuntu系统镜像文件名
  static const String ubuntuFileName = 'ubuntu-noble-aarch64-pd-v4.18.0.tar.xz';

  // GitHub 仓库信息
  static const String githubOwner = 'MuFengDR';
  static const String githubRepo = 'AstrBot-Bubble-Android-App';
  static const String githubReleasesPath =
      '/repos/$githubOwner/$githubRepo/releases/latest';

  // 实测可用于 GitHub Release API 的固定回退源。
  static const String githubApiFallback = 'https://gh-proxy.com';

  // GitHub 官方 API
  static const String githubApi = 'https://api.github.com';

  // GitHub 官方下载地址
  static const String githubDownloadBase =
      'https://github.com/$githubOwner/$githubRepo/releases/download';

  // 下载镜像源列表
  static const List<Map<String, String>> downloadMirrors = [
    {
      'name': 'Ghfast镜像下载',
      'icon': 'speed',
      'url': 'https://ghfast.top',
    },
    {
      'name': 'GHProxy镜像下载',
      'icon': 'speed',
      'url': 'https://gh-proxy.com',
    },
    {
      'name': 'Mirror GHProxy镜像下载',
      'icon': 'speed',
      'url': 'https://mirror.ghproxy.com',
    },
    {
      'name': 'Hub Gitmirror镜像下载',
      'icon': 'speed',
      'url': 'https://hub.gitmirror.com',
    },
  ];
}
