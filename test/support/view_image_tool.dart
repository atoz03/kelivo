/// The image-returning tool that providers recognise by name and by successful
/// result metadata.
const viewImageTools = <Map<String, dynamic>>[
  {
    'type': 'function',
    'function': {
      'name': 'view_image',
      'strict': false,
      'description':
          'View a local image file when visual inspection is needed.',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Local filesystem path to an image file.',
          },
        },
        'additionalProperties': false,
        'required': ['path'],
      },
    },
  },
];

Map<String, dynamic> viewImageMetadata(String status, {String? code}) => {
  'workspace': {'tool': 'view_image', 'status': status, 'code': code},
};
