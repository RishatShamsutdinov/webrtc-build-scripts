{
  'includes': [
    'webrtc/build/common.gypi',
  ],
  'conditions': [
    ['OS=="ios" or (OS=="mac" and mac_deployment_target=="10.7")', {
      'targets': [
        {
          'target_name': 'libWebRTC_objc',
          'type': 'shared_library',
          'dependencies': [
            '<(webrtc_root)/system_wrappers/system_wrappers.gyp:field_trial_default',
            '<(webrtc_root)/system_wrappers/system_wrappers.gyp:metrics_default',
            '<(webrtc_root)/sdk/sdk.gyp:rtc_sdk_peerconnection_objc',
          ],
          'sources': [
          ],
          'export_dependent_settings': [
            '<(webrtc_root)/sdk/sdk.gyp:rtc_sdk_peerconnection_objc',
          ],
          'xcode_settings': {
            'CLANG_ENABLE_OBJC_ARC': 'YES',
          },
        },
      ],  # targets
    }],  # OS=="ios" or (OS=="mac" and mac_deployment_target=="10.7")
  ],
}
