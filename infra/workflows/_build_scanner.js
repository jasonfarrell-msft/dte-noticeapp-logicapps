// Build helper: emits scanner.json. Run: node _build_scanner.js
// This file is NOT deployed; it's just a maintenance helper to keep the inline JS
// extractor readable instead of pre-escaped inside a JSON string.
const fs = require('fs');
const path = require('path');

const JS_DISCOVER = fs.readFileSync(path.join(__dirname, 'discover-bus.js'), 'utf8').trim();

const ASSET_ID = "coalesce(items('JSON_For_Each_Unit')?['value'], items('JSON_For_Each_Unit')?['assetId'])";

function htmlCase() {
  return {
    case: 'html-table-v1',
    actions: {
      HTML_For_Each_Unit: {
        type: 'Foreach',
        foreach: "@outputs('Discover_BUs_JS')['businessUnits']",
        actions: {
          HTML_Get_NoticesList: {
            type: 'Http',
            inputs: {
              method: 'GET',
              uri: "@{replace(replace(items('For_Each_Site')?['config']?['listUrlPattern'], '{code}', items('HTML_For_Each_Unit')?['code']), '{noticeId}', '')}",
              headers: { 'User-Agent': 'CriticalNotice-Scanner/4.0' }
            },
            runAfter: {}
          },
          HTML_Parse_Notices: {
            type: 'Compose',
            inputs: "@split(body('HTML_Get_NoticesList'), '<tr')",
            runAfter: { HTML_Get_NoticesList: ['Succeeded'] }
          },
          HTML_Extract_Notice_Data: {
            type: 'Select',
            inputs: {
              from: "@outputs('HTML_Parse_Notices')",
              select: {
                hasNotice:    "@contains(item(), concat(items('For_Each_Site')?['config']?['noticeIdToken'], '='))",
                noticeId:     "@if(contains(item(), concat(items('For_Each_Site')?['config']?['noticeIdToken'], '=')), split(split(item(), concat(items('For_Each_Site')?['config']?['noticeIdToken'], '='))[1], '&')[0], '')",
                postedDateRaw: "@if(and(contains(item(), '</td><td>'), contains(item(), '/')), split(split(item(), '</td><td>')[1], '</td>')[0], '')"
              }
            },
            runAfter: { HTML_Parse_Notices: ['Succeeded'] }
          },
          HTML_Filter_Valid: {
            type: 'Query',
            inputs: {
              from: "@body('HTML_Extract_Notice_Data')",
              where: "@and(not(equals(item()?['noticeId'], '')), item()?['hasNotice'])"
            },
            runAfter: { HTML_Extract_Notice_Data: ['Succeeded'] }
          },
          HTML_Process_Each_Notice: {
            type: 'Foreach',
            foreach: "@body('HTML_Filter_Valid')",
            actions: {
              HTML_Check_Already_Processed: {
                type: 'Http',
                inputs: {
                  method: 'HEAD',
                  uri: "https://@{parameters('storageAccountName')}.blob.core.windows.net/critical-notices/notices/@{items('For_Each_Site')?['id']}/@{items('HTML_For_Each_Unit')?['code']}/@{items('HTML_Process_Each_Notice')?['noticeId']}.json",
                  authentication: { type: 'ManagedServiceIdentity', audience: 'https://storage.azure.com/' },
                  headers: { 'x-ms-version': '2020-10-02' }
                },
                runAfter: {}
              },
              HTML_Download_If_New: {
                type: 'If',
                expression: { equals: ["@outputs('HTML_Check_Already_Processed')['statusCode']", 404] },
                actions: {
                  HTML_Call_Downloader: {
                    type: 'Http',
                    inputs: {
                      method: 'POST',
                      uri: "@{parameters('downloaderCallbackUrl')}",
                      headers: { 'Content-Type': 'application/json' },
                      body: {
                        source:       "@{items('For_Each_Site')?['id']}",
                        parserModel:  "@{items('For_Each_Site')?['parserModel']}",
                        pipeline:     "@{items('HTML_For_Each_Unit')?['code']}",
                        pipelineName: "@{items('HTML_For_Each_Unit')?['name']}",
                        noticeId:     "@{items('HTML_Process_Each_Notice')?['noticeId']}",
                        url:          "@{replace(replace(items('For_Each_Site')?['config']?['detailUrlPattern'], '{code}', items('HTML_For_Each_Unit')?['code']), '{noticeId}', items('HTML_Process_Each_Notice')?['noticeId'])}",
                        postedDate:   "@{items('HTML_Process_Each_Notice')?['postedDateRaw']}"
                      }
                    },
                    runAfter: {}
                  }
                },
                else: { actions: {} },
                runAfter: { HTML_Check_Already_Processed: ['Succeeded', 'Failed'] }
              }
            },
            runAfter: { HTML_Filter_Valid: ['Succeeded'] },
            runtimeConfiguration: { concurrency: { repetitions: 3 } }
          },
          HTML_Update_Tracking: {
            type: 'Http',
            inputs: {
              method: 'PUT',
              uri: "https://@{parameters('storageAccountName')}.blob.core.windows.net/critical-notices/tracking/@{items('For_Each_Site')?['id']}/@{items('HTML_For_Each_Unit')?['code']}.json",
              authentication: { type: 'ManagedServiceIdentity', audience: 'https://storage.azure.com/' },
              headers: {
                'x-ms-version': '2020-10-02',
                'x-ms-blob-type': 'BlockBlob',
                'Content-Type': 'application/json'
              },
              body: {
                source:           "@{items('For_Each_Site')?['id']}",
                parserModel:      "@{items('For_Each_Site')?['parserModel']}",
                pipeline:         "@{items('HTML_For_Each_Unit')?['code']}",
                pipelineName:     "@{items('HTML_For_Each_Unit')?['name']}",
                lastChecked:      "@{utcNow()}",
                lastSeenNoticeId: "@{if(greater(length(body('HTML_Filter_Valid')), 0), first(body('HTML_Filter_Valid'))?['noticeId'], '')}",
                noticesInWindow:  "@{length(body('HTML_Filter_Valid'))}"
              }
            },
            runAfter: { HTML_Process_Each_Notice: ['Succeeded'] }
          }
        },
        runAfter: {},
        runtimeConfiguration: { concurrency: { repetitions: 5 } }
      }
    }
  };
}

function jsonCase() {
  return {
    case: 'json-grid-v1',
    actions: {
      JSON_For_Each_Unit: {
        type: 'Foreach',
        foreach: "@outputs('Discover_BUs_JS')['businessUnits']",
        actions: {
          JSON_Get_NoticesList: {
            type: 'Http',
            inputs: {
              method: 'GET',
              uri: "@{replace(replace(items('For_Each_Site')?['config']?['listUrlPattern'], '{assetId}', " + ASSET_ID + "), '{noticeId}', '')}",
              headers: {
                'User-Agent': 'CriticalNotice-Scanner/4.0',
                'Accept': 'application/json'
              }
            },
            runAfter: {}
          },
          JSON_Parse_NoticesList: {
            type: 'ParseJson',
            inputs: {
              content: "@body('JSON_Get_NoticesList')",
              schema: {
                type: 'object',
                properties: {
                  total:   { type: 'string' },
                  page:    { type: 'string' },
                  records: { type: 'string' },
                  rows: {
                    type: 'array',
                    items: {
                      type: 'object',
                      properties: {
                        id:   { type: 'string' },
                        cell: { type: 'array', items: { type: 'string' } }
                      }
                    }
                  }
                }
              }
            },
            runAfter: { JSON_Get_NoticesList: ['Succeeded'] }
          },
          JSON_Process_Each_Notice: {
            type: 'Foreach',
            foreach: "@body('JSON_Parse_NoticesList')?['rows']",
            actions: {
              JSON_Extract_Notice_Fields: {
                type: 'Compose',
                inputs: {
                  noticeId:   "@{items('JSON_Process_Each_Notice')?['cell'][0]}",
                  title:      "@{items('JSON_Process_Each_Notice')?['cell'][1]}",
                  postedDate: "@{items('JSON_Process_Each_Notice')?['cell'][2]}"
                },
                runAfter: {}
              },
              JSON_Check_Already_Processed: {
                type: 'Http',
                inputs: {
                  method: 'HEAD',
                  uri: "https://@{parameters('storageAccountName')}.blob.core.windows.net/critical-notices/notices/@{items('For_Each_Site')?['id']}/@{items('JSON_For_Each_Unit')?['code']}/@{outputs('JSON_Extract_Notice_Fields')?['noticeId']}.json",
                  authentication: { type: 'ManagedServiceIdentity', audience: 'https://storage.azure.com/' },
                  headers: { 'x-ms-version': '2020-10-02' }
                },
                runAfter: { JSON_Extract_Notice_Fields: ['Succeeded'] }
              },
              JSON_Download_If_New: {
                type: 'If',
                expression: { equals: ["@outputs('JSON_Check_Already_Processed')['statusCode']", 404] },
                actions: {
                  JSON_Call_Downloader: {
                    type: 'Http',
                    inputs: {
                      method: 'POST',
                      uri: "@{parameters('downloaderCallbackUrl')}",
                      headers: { 'Content-Type': 'application/json' },
                      body: {
                        source:       "@{items('For_Each_Site')?['id']}",
                        parserModel:  "@{items('For_Each_Site')?['parserModel']}",
                        pipeline:     "@{items('JSON_For_Each_Unit')?['code']}",
                        pipelineName: "@{items('JSON_For_Each_Unit')?['name']}",
                        assetId:      "@{" + ASSET_ID + "}",
                        noticeId:     "@{outputs('JSON_Extract_Notice_Fields')?['noticeId']}",
                        title:        "@{outputs('JSON_Extract_Notice_Fields')?['title']}",
                        url:          "@{replace(replace(items('For_Each_Site')?['config']?['detailUrlPattern'], '{assetId}', " + ASSET_ID + "), '{noticeId}', outputs('JSON_Extract_Notice_Fields')?['noticeId'])}",
                        postedDate:   "@{outputs('JSON_Extract_Notice_Fields')?['postedDate']}"
                      }
                    },
                    runAfter: {}
                  }
                },
                else: { actions: {} },
                runAfter: { JSON_Check_Already_Processed: ['Succeeded', 'Failed'] }
              }
            },
            runAfter: { JSON_Parse_NoticesList: ['Succeeded'] },
            runtimeConfiguration: { concurrency: { repetitions: 3 } }
          },
          JSON_Update_Tracking: {
            type: 'Http',
            inputs: {
              method: 'PUT',
              uri: "https://@{parameters('storageAccountName')}.blob.core.windows.net/critical-notices/tracking/@{items('For_Each_Site')?['id']}/@{items('JSON_For_Each_Unit')?['code']}.json",
              authentication: { type: 'ManagedServiceIdentity', audience: 'https://storage.azure.com/' },
              headers: {
                'x-ms-version': '2020-10-02',
                'x-ms-blob-type': 'BlockBlob',
                'Content-Type': 'application/json'
              },
              body: {
                source:       "@{items('For_Each_Site')?['id']}",
                parserModel:  "@{items('For_Each_Site')?['parserModel']}",
                pipeline:     "@{items('JSON_For_Each_Unit')?['code']}",
                pipelineName: "@{items('JSON_For_Each_Unit')?['name']}",
                assetId:      "@{" + ASSET_ID + "}",
                lastChecked:  "@{utcNow()}",
                totalRecords: "@{body('JSON_Parse_NoticesList')?['records']}"
              }
            },
            runAfter: { JSON_Process_Each_Notice: ['Succeeded'] }
          }
        },
        runAfter: {},
        runtimeConfiguration: { concurrency: { repetitions: 3 } }
      }
    }
  };
}

const workflow = {
  $schema: 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#',
  contentVersion: '4.0.0',
  parameters: {
    storageAccountName:    { type: 'String' },
    downloaderCallbackUrl: { type: 'String' },
    backfillDays:          { type: 'Int', defaultValue: 10 },
    registryBlobPath: {
      type: 'String',
      defaultValue: 'critical-notices/config/sites.json',
      metadata: { description: 'Container/path to the site registry blob; read at runtime.' }
    }
  },
  triggers: {
    Recurrence_15_Minutes: {
      type: 'Recurrence',
      recurrence: { frequency: 'Minute', interval: 15 }
    }
  },
  actions: {
    Initialize_BackfillCutoffDate: {
      type: 'InitializeVariable',
      inputs: {
        variables: [{
          name: 'backfillCutoffDate',
          type: 'string',
          value: "@{formatDateTime(addDays(utcNow(), mul(-1, parameters('backfillDays'))), 'yyyy-MM-dd')}"
        }]
      },
      runAfter: {}
    },
    Get_Site_Registry: {
      type: 'Http',
      inputs: {
        method: 'GET',
        uri: "https://@{parameters('storageAccountName')}.blob.core.windows.net/@{parameters('registryBlobPath')}",
        authentication: { type: 'ManagedServiceIdentity', audience: 'https://storage.azure.com/' },
        headers: { 'x-ms-version': '2020-10-02' }
      },
      runAfter: { Initialize_BackfillCutoffDate: ['Succeeded'] }
    },
    Parse_Registry: {
      type: 'ParseJson',
      inputs: {
        content: "@body('Get_Site_Registry')",
        schema: {
          type: 'object',
          properties: {
            version: { type: 'string' },
            sites: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  id:          { type: 'string' },
                  name:        { type: 'string' },
                  enabled:     { type: 'boolean' },
                  parserModel: { type: 'string' },
                  discovery:   { type: 'object' },
                  config:      { type: 'object' }
                },
                required: ['id', 'enabled', 'parserModel', 'discovery', 'config']
              }
            }
          }
        }
      },
      runAfter: { Get_Site_Registry: ['Succeeded'] }
    },
    Filter_Enabled_Sites: {
      type: 'Query',
      inputs: {
        from: "@body('Parse_Registry')?['sites']",
        where: "@equals(item()?['enabled'], true)"
      },
      runAfter: { Parse_Registry: ['Succeeded'] }
    },
    For_Each_Site: {
      type: 'Foreach',
      foreach: "@body('Filter_Enabled_Sites')",
      actions: {
        Compose_Discovery_Inputs: {
          type: 'Compose',
          inputs: {
            siteId:        "@{items('For_Each_Site')?['id']}",
            parserModel:   "@{items('For_Each_Site')?['parserModel']}",
            rootUrl:       "@{items('For_Each_Site')?['discovery']?['rootUrl']}",
            dropdownLabel: "@{items('For_Each_Site')?['discovery']?['dropdownLabel']}"
          },
          runAfter: {}
        },
        Get_RootHtml: {
          type: 'Http',
          inputs: {
            method: 'GET',
            uri: "@{outputs('Compose_Discovery_Inputs')['rootUrl']}",
            headers: { 'User-Agent': 'CriticalNotice-Scanner/4.0' }
          },
          runAfter: { Compose_Discovery_Inputs: ['Succeeded'] }
        },
        Read_Discovery_Cache: {
          type: 'Http',
          inputs: {
            method: 'GET',
            uri: "https://@{parameters('storageAccountName')}.blob.core.windows.net/critical-notices/discovery/@{items('For_Each_Site')?['id']}.json",
            authentication: { type: 'ManagedServiceIdentity', audience: 'https://storage.azure.com/' },
            headers: { 'x-ms-version': '2020-10-02' }
          },
          runAfter: { Get_RootHtml: ['Succeeded', 'Failed'] }
        },
        Discover_BUs_JS: {
          type: 'JavaScriptCode',
          inputs: {
            code: JS_DISCOVER,
            explicitDependencies: {
              actions: ['Get_RootHtml', 'Read_Discovery_Cache', 'Compose_Discovery_Inputs']
            }
          },
          runAfter: { Read_Discovery_Cache: ['Succeeded', 'Failed'] }
        },
        If_Have_BUs: {
          type: 'If',
          expression: { greater: ["@outputs('Discover_BUs_JS')['count']", 0] },
          actions: {
            If_Source_Live: {
              type: 'If',
              expression: { equals: ["@outputs('Discover_BUs_JS')['source']", 'live'] },
              actions: {
                Write_Discovery_Cache: {
                  type: 'Http',
                  inputs: {
                    method: 'PUT',
                    uri: "https://@{parameters('storageAccountName')}.blob.core.windows.net/critical-notices/discovery/@{items('For_Each_Site')?['id']}.json",
                    authentication: { type: 'ManagedServiceIdentity', audience: 'https://storage.azure.com/' },
                    headers: {
                      'x-ms-version': '2020-10-02',
                      'x-ms-blob-type': 'BlockBlob',
                      'Content-Type': 'application/json'
                    },
                    body: "@outputs('Discover_BUs_JS')"
                  },
                  runAfter: {}
                }
              },
              else: { actions: {} },
              runAfter: {}
            },
            Dispatch_By_ParserModel: {
              type: 'Switch',
              expression: "@items('For_Each_Site')?['parserModel']",
              cases: {
                case_html_table_v1: htmlCase(),
                case_json_grid_v1:  jsonCase()
              },
              default: {
                actions: {
                  Log_Unknown_ParserModel: {
                    type: 'Compose',
                    inputs: {
                      level: 'warning',
                      message: 'Unknown parserModel; site skipped.',
                      siteId:      "@{items('For_Each_Site')?['id']}",
                      parserModel: "@{items('For_Each_Site')?['parserModel']}"
                    }
                  }
                }
              },
              runAfter: { If_Source_Live: ['Succeeded'] }
            }
          },
          else: {
            actions: {
              Log_Skip_Site: {
                type: 'Compose',
                inputs: {
                  level: 'warning',
                  message: 'Site skipped: discovery returned 0 BUs and no usable cache.',
                  siteId:         "@{items('For_Each_Site')?['id']}",
                  discoveryError: "@{outputs('Discover_BUs_JS')['discoveryError']}",
                  reason:         "@{outputs('Discover_BUs_JS')['reason']}"
                }
              }
            }
          },
          runAfter: { Discover_BUs_JS: ['Succeeded'] }
        }
      },
      runAfter: { Filter_Enabled_Sites: ['Succeeded'] },
      runtimeConfiguration: { concurrency: { repetitions: 2 } }
    },
    Project_SiteIds: {
      type: 'Select',
      inputs: {
        from: "@body('Filter_Enabled_Sites')",
        select: "@item()?['id']"
      },
      runAfter: { For_Each_Site: ['Succeeded', 'Failed'] }
    },
    Update_Scan_Summary: {
      type: 'Http',
      inputs: {
        method: 'PUT',
        uri: "https://@{parameters('storageAccountName')}.blob.core.windows.net/critical-notices/tracking/scan-summary.json",
        authentication: { type: 'ManagedServiceIdentity', audience: 'https://storage.azure.com/' },
        headers: {
          'x-ms-version': '2020-10-02',
          'x-ms-blob-type': 'BlockBlob',
          'Content-Type': 'application/json'
        },
        body: {
          lastScanCompleted:  "@{utcNow()}",
          lastRunStatus:      "@{result('For_Each_Site')?[0]?['status']}",
          registryVersion:    "@{body('Parse_Registry')?['version']}",
          backfillWindowDays: "@{parameters('backfillDays')}",
          backfillCutoffDate: "@{variables('backfillCutoffDate')}",
          sitesScanned:       "@{length(body('Filter_Enabled_Sites'))}",
          siteIds:            "@{join(body('Project_SiteIds'), ',')}"
        }
      },
      runAfter: { Project_SiteIds: ['Succeeded'] }
    }
  },
  outputs: {}
};

const out = path.join(__dirname, 'scanner.json');
fs.writeFileSync(out, JSON.stringify({ definition: workflow, kind: 'Stateful' }, null, 2));
console.log('wrote', out, fs.statSync(out).size, 'bytes');
