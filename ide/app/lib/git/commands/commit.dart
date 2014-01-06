// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library git.commands.commit;

import 'dart:async';
import 'dart:typed_data';

import 'package:chrome_gen/chrome_app.dart' as chrome;

import '../file_operations.dart';
import '../object.dart';
import '../object_utils.dart';
import '../objectstore.dart';
import '../options.dart';
import '../utils.dart';

/**
 * This class implments the git commit command.
 */
class Commit {

  /**
   * Walks over all the files in the working tree. Returns sha of the
   * working tree.
   */
  static Future<String> walkFiles(chrome.DirectoryEntry root,
      ObjectStore store) {
    Completer completer = new Completer();

    FileOps.listFiles(root).then((List<chrome.DirectoryEntry> entries) {
      if (entries.isEmpty) {
        return null;
      }

      List<TreeEntry> treeEntries = [];

      Future.forEach(entries, (chrome.DirectoryEntry entry) {
        if (entry.name == '.git') {
          return;
        }

        if (entry.isDirectory) {
          walkFiles(entry, store).then((String sha) {
            if (sha != null) {
              treeEntries.add(new TreeEntry(entry.name, shaToBytes(sha),
                  false));
            }
            return;
          });
        } else {
          (entry as chrome.ChromeFileEntry).readBytes().then(
              (chrome.ArrayBuffer buf) {
            store.writeRawObject('blob', new Uint8List.fromList(
                buf.getBytes())).then((String sha) {
              treeEntries.add(new TreeEntry(entry.name, shaToBytes(sha), true));
              return;
            });
          });
        }
      }).then((_) {
        treeEntries.sort((TreeEntry a, TreeEntry b) {
          String aName = a.isBlob ? a.name : (a.name + '/');
          String bName = b.isBlob ? b.name : (b.name + '/');
          return aName.compareTo(bName);
        });
        store.writeTree(treeEntries).then((String result) {
          completer.complete(result);
        });
      });
    });

    return completer.future;
  }

  static Future checkTreeChanged(ObjectStore store, String parent,
      String sha) {
    if (parent.isEmpty) {
      return null;
    } else {
      return store.retrieveObject(parent, ObjectTypes.COMMIT).then(
          (CommitObject parentCommit) {
        String oldTree = parentCommit.treeSha;
        if (oldTree == sha) {
          // TODO throw COMMITS_NO_CHANGES error.
          throw "commits_no_changes";
        } else {
          return null;
        }
      }, onError: (e) {
        //TODO throw error object_store_corrupted.
        throw "object_store_corrupted";
      });
    }
  }

  /**
   * Creates a commit of all the changed files int the working tree with
   * [options.commitMessage] as commit message.
   */
  static Future commit(GitOptions options) {
    chrome.DirectoryEntry dir = options.root;
    ObjectStore store = options.store;

    Completer completer = new Completer();

    store.getHeadRef().then((String headRefName) {
      store.getHeadForRef(headRefName).then((String parent) {
        _createCommitFromWorkingTree(options, parent, headRefName).then(
            (String str) {
              completer.complete(str);
            }, onError: (e) => throw e);
      }, onError: (e) {
        _createCommitFromWorkingTree(options, null, headRefName).then(
            (String str) => completer.complete(str), onError: (e) => throw e);
      });
    });

    return completer.future;
  }

  static Future _createCommitFromWorkingTree(GitOptions options, String parent,
      String refName) {
    chrome.DirectoryEntry dir = options.root;
    ObjectStore store = options.store;
    String name = options.name;
    String email = options.email;
    String commitMsg = options.commitMessage;

    Completer completer = new Completer();

    walkFiles(dir, store).then((String sha) {
      checkTreeChanged(store, parent, sha).then((_) {
        DateTime now = new DateTime.now();
        String dateString = (now.millisecond / 1000).floor().toString();
        int offset = (now.timeZoneOffset.inMilliseconds / -60).floor();
        int absOffset = offset.abs().floor();
        String offsetStr = '' + (offset < 0 ? '-' : '+');
        offsetStr += (absOffset < 10 ? '0' : '') + '${absOffset}00';
        dateString += offsetStr;
        List<String> commitParts = [];
        commitParts.add('tree ${sha}\n');
        if (parent != null && parent.length) {
          commitParts.add('parent ${parent}');
          if (parent[parent.length -1] != '\n') {
            commitParts.add('\n');
          }
        }

        commitParts.add('author ${name} ');
        commitParts.add(' <$email> ');
        commitParts.add(dateString);
        commitParts.add('\n');
        commitParts.add('committer ${name}');
        commitParts.add(' <${email}>');
        commitParts.add(dateString);
        commitParts.add('\n\n${commitMsg}\n');

        StringBuffer commitContent = new StringBuffer(commitParts);
        store.writeRawObject('commit', commitContent.toString()).then(
            (String commitSha) {
          FileOps.createFileWithContent(dir, '.git/${refName}',
              commitSha + '\n', 'Text').then((_) {
                store.updateLastChange(null).then((_) {
                  completer.complete(commitSha);
                },
                onError: (e) => completer.completeError(e));
          });
        });
      });
    });

    return completer.future;
  }
}
