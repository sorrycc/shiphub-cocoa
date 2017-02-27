import 'font-awesome/css/font-awesome.css'
import '../markdown-mark/style.css'
import 'codemirror/lib/codemirror.css'
import 'highlight.js/styles/xcode.css'
import './issue.css'

import React, { createElement as h } from 'react'
import ReactDOM from 'react-dom'
import escape from 'html-escape'
import linkify from 'html-linkify'
import md5 from 'md5'
import 'whatwg-fetch'
import Textarea from 'react-textarea-autosize'

import $ from 'jquery'
window.$ = $;
window.jQuery = $;
window.jquery = $;

import Completer from 'components/issue/completer.js'
import SmartInput from 'components/issue/smart-input.js'
import { emojify, emojifyReaction } from 'util/emojify.js'
import { githubLinkify } from 'util/github-linkify.js'
import LabelPicker from 'components/issue/label-picker.js'
import AssigneesPicker from 'components/issue/assignees-picker.js'
import { TimeAgo, TimeAgoString } from 'components/time-ago.js'
import { api } from 'util/api-proxy.js'
import { promiseQueue } from 'util/promise-queue.js'
import ghost from 'util/ghost.js'
import IssueState from './issue-state.js'
import { keypath, setKeypath } from 'util/keypath.js'

import AvatarIMG from 'components/AvatarIMG.js'
import Comment from 'components/comment/Comment.js'

var EventIcon = React.createClass({
  propTypes: {
    event: React.PropTypes.string.isRequired
  },
  
  render: function() {
    var icon;
    var pushX = 0;
    var color = null;
    switch (this.props.event) {
      case "assigned":
        icon = "user";
        break;
      case "unassigned":
        icon = "user-times";
        break;
      case "labeled":
        icon = "tags";
        break;
      case "unlabeled":
        icon = "tags";
        break;
      case "opened":
      case "reopened":
        icon = "circle-o";
        color = "green";
        break;
      case "closed":
        icon = "times-circle-o";
        color = "red";
        break;
      case "milestoned":
        icon = "calendar";
        break;
      case "unmilestoned":
      case "demilestoned":
        icon = "calendar-times-o";
        break;
      case "locked":
        icon = "lock";
        pushX = "2";
        break;
      case "unlocked":
        icon = "unlock";
        break;
      case "renamed":
        icon = "pencil-square";
        break;
      case "referenced":
      case "merged":
        icon = "git-square";
        break;
      case "cross-referenced":
        icon = "hand-o-right";
        break;
      case "converted_note_to_issue":
        icon = "trello";
        break;
      default:
        console.log("unknown event", this.props.event);
        icon = "exclamation-circle";
        break;
    }
    
    var opts = {className:"eventIcon fa fa-" + icon, style: {}};
    if (pushX != 0) {
      opts.style.paddingLeft = pushX;
    }
    if (color) {
      opts.style.color = color;
    }
    return h("i", opts);
  }
});

var EventUser = React.createClass({
  propTypes: { user: React.PropTypes.object },
  getDefaultProps: function() {
    return {
      user: ghost
    };
  },
  
  render: function() {
    var user = this.props.user || ghost;
    return h("span", {className:"eventUser"},
      h(AvatarIMG, {user:user, size:16}),
      user.login
    );
  }
});

var AssignedEventDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    var actor = this.props.event.assigner || this.props.event.actor || ghost;
    var assignee = this.props.event.assignee || ghost;
    if (assignee.id == actor.id) {
      return h("span", {}, "self assigned this");
    } else {
      return h("span", {},
        h("span", {}, "assigned this to "),
        h(EventUser, {user:this.props.event.assignee})
      );
    }
  }
});

var UnassignedEventDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    var actor = this.props.event.assigner || this.props.event.actor || ghost;
    var assignee = this.props.event.assignee || ghost;
    if (assignee.id == actor.id) {
      return h("span", {}, "is no longer assigned");
    } else {
      return h("span", {}, "removed assignee ", h(EventUser, {user:this.props.event.assignee}));
    }
  }
});

var MilestoneEventDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    if (this.props.event.milestone) {
      if (this.props.event.event == "milestoned") {
        return h("span", {},
          "modified the milestone: ",
          h("span", {className: "eventMilestone"}, this.props.event.milestone.title)
        );
      } else {
        return h("span", {},
          "removed the milestone: ",
          h("span", {className: "eventMilestone"}, this.props.event.milestone.title)
        );
      }
    } else {
      return h("span", {}, "unset the milestone");
    }
  }
});

var Label = React.createClass({
  propTypes: { 
    label: React.PropTypes.object.isRequired,
    canDelete: React.PropTypes.bool,
    onDelete: React.PropTypes.func,
  },
  
  onDeleteClick: function() {
    if (this.props.onDelete) {
      this.props.onDelete(this.props.label);
    }
  },
  
  render: function() {
    // See http://stackoverflow.com/questions/12043187/how-to-check-if-hex-color-is-too-black
    var rgb = parseInt(this.props.label.color, 16);   // convert rrggbb to decimal
    var r = (rgb >> 16) & 0xff;  // extract red
    var g = (rgb >>  8) & 0xff;  // extract green
    var b = (rgb >>  0) & 0xff;  // extract blue

    var luma = 0.2126 * r + 0.7152 * g + 0.0722 * b; // per ITU-R BT.709

    var textColor = luma < 128 ? "white" : "black";
    
    var extra = [];
    var style = {backgroundColor:"#"+this.props.label.color, color:textColor};
    
    if (this.props.canDelete) {
      extra.push(h('span', {className:'LabelDelete Clickable', onClick:this.onDeleteClick}, 
        h('i', {className:'fa fa-trash-o'})
      ));
      style = Object.assign({}, style, {borderTopRightRadius:"0px", borderBottomRightRadius:"0px"});
    }
    
    return h("span", {className:"LabelContainer"},
      h("span", {className:"label", style:style},
        this.props.label.name
      ),
      ...extra
    );
  }
});

var LabelEventDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    var elements = [];
    elements.push(this.props.event.event);
    var labels = this.props.event.labels.filter(function(l) { return l != null && l.name != null; });
    elements = elements.concat(labels.map(function(l, i) {
      return [" ", h(Label, {key:i, label:l})]
    }).reduce(function(c, v) { return c.concat(v); }, []));
    return h("span", {}, elements);
  }
});

var RenameEventDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    return h("span", {}, 
      "changed the title from ",
      h("span", {className:"eventTitle"}, this.props.event.rename.from || "empty"),
      " to ",
      h("span", {className:"eventTitle"}, this.props.event.rename.to || "empty")
    );
  }
});

function expandCommit(event) {
  try {
    var committish = event.commit_id.slice(0, 10);
    var commitURL = event.commit_url.replace("api.github.com/repos/", "github.com/").replace("/commits/", "/commit/");
    return [committish, commitURL];
  } catch (exc) {
    console.log("Unable to expand commit", exc, event);
    return ["", ""];
  }
}

var ReferencedEventDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  
  willCloseIssueOnMerge: function() {
    var info = getOwnerRepoTypeNumberFromURL(this.props.event.commit_url);
    var issue = IssueState.current.issue;
    
    if (issue.state != "open") {
      // if the issue is already closed, this commit won't close it further.
      return false;
    }
    
    if (info.owner != IssueState.current.repoOwner ||
        info.repo != IssueState.current.repoName)
    {
      // commit is in a different repo. it won't close it.
      return false;
    }
    
    var msg = this.props.event.ship_commit_message || "";
    var fixes = /(?:close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)\s+((?:[\w\d\-_]+\/[\w\d\-_]+)#\d+)/gi;
    var allFixes = matchAll(fixes, msg);
    var issueNum = "#" + (issue.number || "");
    var fullIssueNum = issue.full_identifier || (IssueState.current.repoOwner + "/" + IssueState.current.repoName + issueNum);
    var fixes = allFixes.map((x) => x[1]).filter((x) => x == issueNum || x == fullIssueNum);
    return fixes.length > 0;
  },
  
  render: function() {
    var [committish, commitURL] = expandCommit(this.props.event);

    var parts = ["referenced this issue in commit ",
                 h("a", {key: "shaLink", className: "shaLink", href:commitURL, target:"_blank"}, committish)];

    if (this.props.event.ship_commit_author &&
        this.props.event.ship_commit_author.login !=
        this.props.event.actor.login) {
      var authoredBy = h("span", {key: "authoredBy"},
                     "(authored by ",
                     h(EventUser, {user: this.props.event.ship_commit_author}),
                     ")"
                    );
      parts.push(authoredBy);
    }
    
    if (this.willCloseIssueOnMerge()) {
      var closeInfo = h("i", {
        key: "willCloseOnMerge",
        className: "fa fa-code-fork", 
        style: { paddingLeft: "4px", paddingRight: "1px" },
        title: "This issue will close once this commit is merged"}
      );
      parts.push(closeInfo);
    }
    
    return h("span", {}, parts);
  }
});

function getOwnerRepoTypeNumberFromURL(url) {
  if (!url) url = "";
  var capture = url.match(
    /https:\/\/api.github.com\/repos\/([^\/]+)\/([^\/]+)\/(issues|pulls|commits)\/([a-z0-9]+)/);

  if (capture) {
    return {
      owner: capture[1],
      repo: capture[2],
      type: capture[3],
      number: capture[4],
    };
  } else {
    return { owner: "", repo: "", type: "", number: "" };
  }
}

var CrossReferencedEventDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    var url = keypath(this.props.event, "source.issue.url") || keypath(this.props.event, "source.url");
  
    var urlParts = getOwnerRepoTypeNumberFromURL(url);

    var referencedRepoName = `${urlParts.owner}/${urlParts.repo}`;
    var repoName = IssueState.current.repoOwner + "/" + IssueState.current.repoName;

    if (repoName === referencedRepoName) {
      return h("span", {}, "referenced this issue");
    } else {
      // Only bother to show the repo name if the reference comes from another repo.
      return h("span", {},
               "referenced this issue in ",
               h("b", {}, referencedRepoName)
              );
    }
  }
});

var MergedEventDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    var [committish, commitURL] = expandCommit(this.props.event);
    return h("span", {},
      "merged this request with commit ",
      h("a", {href:commitURL, target:"_blank"}, committish)
    );
  }
});

var ClosedEventDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    if (typeof(this.props.event.commit_id) === "string") {
      var [committish, commitURL] = expandCommit(this.props.event);

      var authoredBy = null;
      if (this.props.event.ship_commit_author &&
          this.props.event.ship_commit_author.login !=
          this.props.event.actor.login) {
        authoredBy = h("span", {key:"authoredBy"},
                       "(authored by ",
                       h(EventUser, {user: this.props.event.ship_commit_author}),
                       ")"
                      );
      }

      return h("span", {key:"with"},
        "closed this issue with commit ",
        h("a",
          {
            className: "shaLink",
            href:commitURL,
            target:"_blank"
          },
          committish),
        authoredBy
      );
    } else {
      return h("span", {key:"without"}, "closed this issue");
    }
  }
});

var ConvertedNoteToIssueDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    console.log("event", this.props.event);
    return h("span", {}, "created this issue from a note");
  }
});
      
var UnknownEventDescription = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    return h("span", {}, this.props.event.event);
  }
});

var ClassForEventDescription = function(event) {
  switch (event.event) {
    case "assigned": return AssignedEventDescription;
    case "unassigned": return UnassignedEventDescription;
    case "milestoned":
    case "demilestoned": return MilestoneEventDescription;
    case "labeled": 
    case "unlabeled": return LabelEventDescription;
    case "renamed": return RenameEventDescription;
    case "referenced": return ReferencedEventDescription;
    case "merged": return MergedEventDescription;
    case "closed": return ClosedEventDescription;
    case "cross-referenced": return CrossReferencedEventDescription;
    case "converted_note_to_issue": return ConvertedNoteToIssueDescription;
    default: return UnknownEventDescription
  }
}

var CrossReferencedEventBody = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },
  render: function() {
    var sourceUrl, issueState, issueTitle, isPullRequest, isPullRequestMerged;
    
    var issue = keypath(this.props.event, "source.issue");
    
    if (issue) {
      issueTitle = issue.title;
      issueState = issue.state;
      sourceUrl = issue.url;
      isPullRequest = !!(issue.pull_request);
      isPullRequestMerged = false;
    } else {
      issueTitle = this.props.event.ship_issue_title;
      issueState = this.props.event.ship_issue_state;
      sourceUrl = this.props.event.source.url;
      isPullRequest = this.props.event.ship_is_pull_request;
      isPullRequestMerged = this.props.event.ship_pull_request_merged;
    }
  
    var issueStateLabel = (issueState === "open") ? "Open" : "Closed";
    var issueStateClass = (issueState === "open") ? "issueStateOpen" : "issueStateClosed";

    if (isPullRequest) {
      if (issueState === "closed" && isPullRequestMerged) {
        issueStateLabel = "Merged";
        issueStateClass = "issueStateMerged";
      }
    } 

    var urlParts = getOwnerRepoTypeNumberFromURL(sourceUrl);
    var destURL =
      `https://github.com/${urlParts.owner}/${urlParts.repo}/` +
      (isPullRequest ? "pull" : "issues") +
      `/${urlParts.number}`;

    return h("div", {},
             h("a",
               {
                 className: "issueTitle",
                 href: destURL,
                 target: "_blank"
               },
               issueTitle,
               " ",
               h("span",
                 {className: "issueNumber"},
                 "#",
                 urlParts.number)
              ),
              " ",
              h("span",
                {className: "issueState " + issueStateClass},
                issueStateLabel)
            );
  }
});

var CommitInfoEventBody = React.createClass({
  propTypes: { event: React.PropTypes.object.isRequired },

  getInitialState: function() {
    return {
      showBody: false,
    };
  },

  toggleBody: function(clickEvent) {
    this.setState({showBody: !this.state.showBody});
    clickEvent.preventDefault();
  },

  getSubjectAndBodyFromMessage: function(message) {
    // GitHub never shows more than the first 69 characters
    // of a commit message without truncation.
    const maxSubjectLength = 69;
    var subject;
    var body;

    var lines = message.split(/\n/);
    var firstLine = lines[0];

    if (firstLine.length > maxSubjectLength) {
      subject = firstLine.substr(0, maxSubjectLength) + "\u2026";
      body = "\u2026" + message.substr(maxSubjectLength).trim();
    } else if (lines.length > 1) {
      subject = firstLine;
      body = lines.slice(1).join("\n").trim();
    } else {
      subject = message;
      body = null;
    }

    return [subject, body];
  },

  render: function() {
    var commitMessage = this.props.event.ship_commit_message || "";
    var message = commitMessage.trim();
    const [subject, body] = this.getSubjectAndBodyFromMessage(message);

    var bodyContent = null;
    if (this.state.showBody && body) {
      const linkifiedBody = githubLinkify(
        IssueState.current.repoOwner,
        IssueState.current.repoName,
        linkify(escape(body), {escape: false}));
      bodyContent = h("pre",
                      {
                        className: "referencedCommitBody",
                        dangerouslySetInnerHTML: {__html: linkifiedBody},
                      });
    }

    var expander = null;
    if (body && body.length > 0) {
      expander =
        h("a",
          {
            href: "#",
            onClick: this.toggleBody
          },
          h("button", {className: "referencedCommitExpander"}, "\u2026")
        );
    }

    const urlParts = getOwnerRepoTypeNumberFromURL(this.props.event.commit_url);
    return h("div", {},
             h("a",
               {
                 className: "referencedCommitSubject",
                 href: `https://github.com/${urlParts.owner}/${urlParts.repo}/commit/${this.props.event.commit_id}`,
                 title: body ? message : ""
               },
               subject
              ),
             expander,
             h("br", {}),
             bodyContent
           );
  },
});

var ClassForEventBody = function(event) {
  switch (event.event) {
    case "cross-referenced": return CrossReferencedEventBody;
    case "referenced": return CommitInfoEventBody;
    case "closed":
      if (typeof(event.commit_id) === "string") {
        return CommitInfoEventBody;
      } else {
        return null;
      }
    default: return null;
  }
}

var Event = React.createClass({
  propTypes: {
    event: React.PropTypes.object.isRequired,
    last: React.PropTypes.bool,
    veryLast: React.PropTypes.bool
  },
  
  render: function() {
    var className = "event";
    if (this.props.first) {
      className += " eventFirst";
    }
    if (this.props.veryLast) {
      className += " eventVeryLast";
    } else if (!this.props.last) {
      className += " eventDelimited";
    } else {
      className += " eventLast";
    }

    var user;
    if (this.props.event.event === 'cross-referenced') {
      user = this.props.event.actor || keypath(this.props.event, "source.actor");
    } else {
      user = this.props.event.actor;
    }

    var eventBodyClass = ClassForEventBody(this.props.event);

    return h('div', {className:className},
      h(EventIcon, {event: this.props.event.event }),
      h("div", {className: "eventContent"},
        h("div", {},
          h(EventUser, {user: user}),
          " ",
          h(ClassForEventDescription(this.props.event), {event: this.props.event}),
          " ",
          h(TimeAgo, {className:"eventTime", live:true, date:this.props.event.created_at})),
        eventBodyClass ? h(eventBodyClass, {event: this.props.event}) : null
      )
    );
  }
});

var ActivityList = React.createClass({
  propTypes: {
    issue: React.PropTypes.object.isRequired
  },
  
  allComments: function() {
    var comments = [];
    for (var k in this.refs) {
      if (k.indexOf("comment.") == 0) {
        var c = this.refs[k];
        comments.push(c);
      }
    }
    return comments;
  },
  
  needsSave: function() {
    var comments = this.allComments();
    return comments.length > 0 && comments.reduce((a, x) => a || x.needsSave(), false);
  },
  
  activeComment: function() {
    var cs = this.allComments().filter((c) => c.isActive());
    if (cs.length > 0) return cs[0];
    return null;
  },
  
  scrollToCommentWithIdentifier: function(commentIdentifier) {
    var c = this.allComments().filter((c) => c.commentIdentifier() === commentIdentifier);
    if (c.length > 0) {
      c[0].scrollIntoView();
    }
  },
  
  save: function() {
    var c = this.allComments();
    return Promise.all(c.filter((x) => x.needsSave()).map((x) => x.save()));
  },
  
  render: function() {        
    var firstComment = {
      body: this.props.issue.body,
      user: this.props.issue.user,
      id: this.props.issue.id,
      updated_at: this.props.issue.updated_at || new Date().toISOString(),
      created_at: this.props.issue.created_at || new Date().toISOString(),
      reactions: this.props.issue.reactions
    };
    
    // need to merge events and comments together into one array, ordered by date
    var eventsAndComments = (!!(firstComment.id) || this.props.issue.savePending) ? [firstComment] : [];
    
    eventsAndComments = eventsAndComments.concat(this.props.issue.events || []);
    eventsAndComments = eventsAndComments.concat(this.props.issue.comments || []);
    
    eventsAndComments = eventsAndComments.sort(function(a, b) {
      if (a == firstComment && b == firstComment) {
        return 0;
      } else if (a == firstComment) {
        return -1;
      } else if (b == firstComment) {
        return 1;
      }
      
      var da = new Date(a.created_at);
      var db = new Date(b.created_at);
      if (da < db) {
        return -1;
      } else if (db < da) {
        return 1;
      } else {
        if (a.id < b.id) {
          return -1;
        } else if (b.id < a.id) {
          return 1;
        } else {
          return 0;
        }
      }
    });
    
    // need to filter certain types of events from displaying
    eventsAndComments = eventsAndComments.filter(function(e) {
      if (e.event == undefined) {
        return true;
      } else {
        switch (e.event) {
          case "subscribed": return false;
          case "mentioned": return false; // mention events are beyond worthless in the GitHub API
          case "referenced": return e.commit_id != null;
          default: return true;
        }
      }
    });
    
    // roll up successive label elements into a single event
    var labelRollup = null;
    eventsAndComments.forEach(function(e) {
      if (e.event == "labeled" || e.event == "unlabeled") {
        if (labelRollup != null) {
          if (labelRollup.event == e.event 
              && labelRollup.actor.id == e.actor.id 
              && new Date(e.created_at) - new Date(labelRollup.created_at) < (2*60*1000 /*2mins*/)) {
            labelRollup.labels.push(e.label);
            e._rolledUp = true;
          } else {
            labelRollup = null;
          }
        }
        if (labelRollup == null) {
          labelRollup = e;
          e.labels = [e.label];
        }
      } else {
        labelRollup = null;
      }
    });
    
    // now filter rolled up labels
    eventsAndComments = eventsAndComments.filter(function(e) { 
      return !(e._rolledUp);
    });
    
    var counter = { c: 0, e: 0 };
    return h('div', {className:'activityContainer'},
      h('div', {className:'activityList'}, 
        eventsAndComments.map(function(e, i, a) {
          if (e.event != undefined) {
            counter.e = counter.e + 1;
            var next = a[i+1];
            return h(Event, {
              key:(e.id?(e.id+"-"+i):""+i), 
              event:e, 
              first:(i==0 || a[i-1].event == undefined),
              last:(next!=undefined && next.event==undefined),
              veryLast:(next==undefined)
            });
          } else {
            counter.c = counter.c + 1;
            return h(Comment, {key:(e.id?(e.id+"-"+i):""+i), ref:"comment." + i, comment:e, first:i==0, commentIdx:counter.c-1})
          }
        })
      )
    );
  }
});

var IssueIdentifier = React.createClass({
  propTypes: { issue: React.PropTypes.object },
  
  render: function() {
    return h('div', { className: 'IssueIdentifier' },
      h('span', { className: 'IssueIdentifierOwnerRepo' },
        this.props.issue._bare_owner + "/" + this.props.issue._bare_repo
      ),
      h('span', { className: 'IssueIdentifierNumber' },
        "#" + this.props.issue.number
      )
    );
  }
});

var HeaderLabel = React.createClass({
  propTypes: { title: React.PropTypes.string },
  
  render: function() {
    return h('span', {className:'HeaderLabel'}, this.props.title + ": ");
  }
});

var HeaderSeparator = React.createClass({
  render: function() {
    return h('div', {className:'HeaderSeparator'});
  }
});

var InputSaveButton = React.createClass({
  
  render: function() {
    var props = Object.assign({}, {className:'InputSaveButton'}, this.props);
    return h('span', props, 'Save ↩︎');
  }
});

var IssueTitle = React.createClass({
  propTypes: { issue: React.PropTypes.object },
  
  titleChanged: function(newTitle, goNext) {
    var promise = null;
    if (this.state.edited) {
      this.setState({edited: false});
      promise = IssueState.current.patchIssue({title: newTitle});
    }
    if (goNext) {
      this.props.focusNext("title");
    }
    return promise || Promise.resolve();
  },

  getInitialState: function() {
    return { edited: false };
  },
  
  componentWillReceiveProps: function(newProps) {
    if (this.state.edited) {
      if (newProps.issue.number == this.props.issue.number) {
        // ignore the change, we're editing!
      } else {
        this.setState({edited: false})
      }
    } else {
      this.setState({edited: false})
    }
  },
  
  onEdit: function(didEdit, editedVal) {
    this.setState({edited: this.props.issue.title != editedVal, editedValue: editedVal})
  },
  
  titleSaveClicked: function(evt) {
    return this.titleChanged(this.state.editedValue, false);
  },
  
  focus: function() {
    this.refs.input.focus()
  },
  
  hasFocus: function() {
    return this.refs.input.hasFocus();
  },
  
  needsSave: function() {
    if (this.refs.input) {
      return this.refs.input.isEdited();
    } else {
      return false;
    }
  },
  
  save: function() {
    if (this.needsSave()) {
      return this.titleSaveClicked();
    } else {
      return Promise.resolve();
    }
  },
  
  componentDidMount: function() {
    if (!window.inColumnBrowser) {
      this.focus();
    }
  },
  
  render: function() {
    var val = this.props.issue.title;
    if (this.state.edited) {
      val = this.state.editedValue;
    }
  
    var children = [
      h(HeaderLabel, {title:'Title'}),
      h(SmartInput, {ref:"input", element:Textarea, initialValue:this.props.issue.title, value:val, className:'TitleArea', onChange:this.titleChanged, onEdit:this.onEdit, placeholder:"Required"}),
      h(IssueNumber, {issue: this.props.issue})
    ];
    
    if (this.state.edited && this.props.issue.number != null) {
      children.splice(2, 0, h(InputSaveButton, {key: "titleSave", onClick: this.titleSaveClicked, style: { marginRight: "8px" } }));
    }
  
    return h('div', {className:'IssueTitle'}, ...children);
  }
});

var IssueNumber = React.createClass({
  propTypes: { issue: React.PropTypes.object },
  render: function() {
    var val = "";
    if (this.props.issue.number) {
      val = this.props.issue.number;
    }
    return h('div', {className:'IssueNumber'},
      val      
    );
  }
});

var RepoField = React.createClass({
  propTypes: { 
    issue: React.PropTypes.object,
    onIssueTemplate: React.PropTypes.func
  },
  
  onChange: function(newRepo, goNext) {
    var fail = () => {
      setTimeout(() => {
        this.refs.input.refs.typeInput.setState({value: this.repoValue()});
      }, 1);
    };
  
    if (newRepo.indexOf('/') == -1) {
      fail();
      return Promise.reject("Invalid repo");
    }
    
    var [owner, repo] = newRepo.split("/");
    
    var repoInfo = IssueState.current.repos.find((x) => x.full_name == newRepo);
    
    if (!repoInfo) {
      fail();
      return Promise.reject("Invalid repo");
    }
    
    var state = IssueState.current.state;
    state = Object.assign({}, state);
    state.issue = Object.assign({}, state.issue, { 
      _bare_repo: repo, 
      _bare_owner: owner,
      repository: null,
      milestone: null,
      assignees: [],
      labels: []
    });
    applyIssueState(state);
    
    return new Promise((resolve, reject) => {
      // fetch new metadata and merge it in
      loadMetadata(newRepo).then((meta) => {
        var state = IssueState.current.state;
        state = Object.assign({}, state, meta);
        var nextIssueState = { 
          _bare_repo: repo, 
          _bare_owner: owner,
          milestone: null,
          assignees: [],
          labels: []
        };
        var issueTemplate = repoInfo.issue_template;
        if ((issueTemplate||"").trim().length > 0 && (keypath(state, "issue.body")||"").trim().length == 0) {
          nextIssueState.body = issueTemplate;
          if (this.props.onIssueTemplate) {
            this.props.onIssueTemplate(issueTemplate);
          }
        }
        state.issue = Object.assign({}, state.issue, nextIssueState);
        applyIssueState(state);
        resolve();
      }).catch((err) => {
        console.log("Could not load metadata for repo", newRepo, err);
        fail();
        reject();
      });      
    });
  },
  
  onEnter: function() {
    var completer = this.refs.input;
    var el = ReactDOM.findDOMNode(completer.refs.typeInput);
    var val = el.value;
    
    var promises = [];
    completer.props.matcher(val, (results) => {
      if (results.length >= 1) {
        var result = results[0];
        promises.push(this.onChange(result));
      }
    });
    
    this.props.focusNext("repo");
    
    return Promise.all(promises);
  },
  
  focus: function() {
    if (this.refs.input) {
      this.refs.input.focus();
    }
  },
  
  hasFocus: function() {
    if (this.refs.completer) {
      return this.refs.input.hasFocus();
    } else {
      return false;
    }
  },
  
  needsSave: function() {
    if (this.refs.input) {
      var canEdit = this.props.issue.number == null;
      return canEdit && this.refs.input.isEdited();
    } else {
      return false;
    }
  },
  
  save: function() {
    if (this.needsSave()) {
      return this.onEnter();
    } else {
      return Promise.resolve();
    }
  },
  
  repoValue: function() {
    var repoValue = "";
    if (this.props.issue._bare_owner && this.props.issue._bare_repo) {
      repoValue = "" + this.props.issue._bare_owner + "/" + this.props.issue._bare_repo;
    }
    return repoValue;
  },
  
  render: function() {  
    var opts = IssueState.current.repos.map((r) => r.full_name);
    var matcher = Completer.SubstrMatcher(opts);
    
    var canEdit = this.props.issue.number == null;
    var inputType = Completer;
    if (!canEdit) {
      inputType = 'input';
    }
    
    return h('div', {className: 'IssueInput RepoField'},
      h(HeaderLabel, {title: 'Repo'}),
      h(inputType, {ref:'input', placeholder: 'Required', onChange:this.onChange, onEnter:this.onEnter, value:this.repoValue(), matcher: matcher, readOnly:!canEdit}),
      h(StateField, {issue: this.props.issue})
    );
  }
});

var MilestoneField = React.createClass({
  propTypes: { 
    issue: React.PropTypes.object,
  },
  
  lookupMilestone: function(value) {
    var ms = IssueState.current.milestones.filter((m) => m.title === value);
    if (ms.length == 0) {
      return null;
    } else {
      return ms[0];
    }
  },
  
  milestoneChanged: function(value) {
    var initial = keypath(this.props.issue, "milestone.title") || "";
    if (value != initial) {
      if (value == null || value.length == 0) { 
        value = null;
      }
      
      return IssueState.current.patchIssue({milestone: this.lookupMilestone(value)});
    } else {
      return Promise.resolve();
    }
  },
  
  onEnter: function() {
    var completer = this.refs.completer;    
    var promises = [];
    
    completer.completeOrFail(() => {
      var val = completer.value();
      if (val == null || val == "") {
        promises.push(this.milestoneChanged(null));
      } else {
        promises.push(this.milestoneChanged(val));
      }
      this.props.focusNext("milestone");
    });
    
    return Promise.all(promises);
  },
  
  onAddNew: function(initialNewTitle) {
    return new Promise((resolve, reject) => {
      var cb = (newMilestones) => {
        if (newMilestones === undefined) {
          // error creating
          reject();
        } else if (newMilestones == null || newMilestones.length == 0) {
          // user cancelled
          this.focus();
          resolve();
        } else {
          // success
          var m = newMilestones[0];
          IssueState.current.milestones.push(m);
          this.props.issue.milestone = m;
          this.forceUpdate();
          return this.milestoneChanged(m.title).then(resolve, reject);
        }
      };
      window.newMilestone(initialNewTitle, 
                          this.props.issue._bare_owner, 
                          this.props.issue._bare_repo,
                          cb);
    });
  },
  
  focus: function() {
    if (this.refs.completer) {
      this.refs.completer.focus();
    }
  },
  
  hasFocus: function() {
    if (this.refs.completer) {
      return this.refs.completer.hasFocus();
    } else {
      return false;
    }
  },
  
  needsSave: function() {
    if (this.refs.completer) {
      return (this.refs.completer.value() || "") != (keypath(this.props.issue, "milestone.title") || "");
    } else {
      return false;
    }
  },
  
  save: function() {
    if (this.needsSave()) {
      return this.onEnter();
    } else {
      return Promise.resolve();
    }
  },
  
  shouldComponentUpdate: function(nextProps, nextState) {
    var nextNum = keypath(nextProps, "issue.number");
    var oldNum = keypath(this.props, "issue.number");
    
    if (nextNum && nextNum == oldNum && this.refs.completer.isEdited()) {
      return false;
    }
    return true;
  },
  
  render: function() {
    var canAddNew = !!this.props.issue._bare_repo;
    var opts = IssueState.current.milestones.map((m) => m.title);
    var matcher = Completer.SubstrMatcher(opts);
    
    return h('div', {className: 'IssueInput MilestoneField'},
      h(HeaderLabel, {title:"Milestone"}),
      h(Completer, {
        ref: 'completer',
        placeholder: 'Backlog',
        onChange: this.milestoneChanged,
        onEnter: this.onEnter,
        newItem: canAddNew ? 'New Milestone' : undefined,
        onAddNew: canAddNew ? this.onAddNew : undefined,
        value: keypath(this.props.issue, "milestone.title"),
        matcher: matcher
      })
    );
  }
});

var StateField = React.createClass({
  propTypes: { 
    issue: React.PropTypes.object
  },
  
  stateChanged: function(evt) {
    IssueState.current.patchIssue({state: evt.target.value});
  },
  
  needsSave: function() {
    return false;
  },
  
  save: function() {
    return Promise.resolve();
  },
  
  render: function() {
    var isNewIssue = !(this.props.issue.number);
    
    if (isNewIssue) {
      return h('span');
    }
  
    return h('select', {className:'IssueState', value:this.props.issue.state, onChange:this.stateChanged},
      h('option', {value: 'open'}, "Open"),
      h('option', {value: 'closed'}, "Closed")
    );
  }
});

var AssigneeInput = React.createClass({
  propTypes: {
    issue: React.PropTypes.object
  },
  
  lookupAssignee: function(value) {
    var us = IssueState.current.assignees.filter((a) => a.login === value);
    if (us.length == 0) {
      return null;
    } else {
      return us[0];
    }
  },
  
  assigneeChanged: function(value) {
    var initial = keypath(this.props.issue, "assignees[0].login") || "";
    if (value != initial) {
      if (value == null || value.length == 0) {
        value = null;
      }
      var assignee = this.lookupAssignee(value);
      if (assignee) {
        return IssueState.current.patchIssue({assignees: [assignee]});
      } else {
        return IssueState.current.patchIssue({assignees: []});
      }
    } else {
      return Promise.resolve();
    }
  },
  
  onEnter: function() {
    var completer = this.refs.completer;
    
    var promises = [];
    completer.completeOrFail(() => {
      var val = completer.value();
      if (val == null || val == "") {
        promises.push(this.assigneeChanged(null));
      } else {
        promises.push(this.assigneeChanged(val));
      }
      this.props.focusNext("assignee");
    });
    
    return Promise.all(promises);
  },
  
  focus: function() {
    if (this.refs.completer) {
      this.refs.completer.focus();
    }
  },
  
  hasFocus: function() {
    if (this.refs.completer) {
      return this.refs.completer.hasFocus();
    } else {
      return false;
    }
  },
  
  needsSave: function() {
    if (this.refs.completer) {
      return (this.refs.completer.value() || "") != (keypath(this.props.issue, "assignees[0].login") || "");
    } else {
      return false;
    }
  },
  
  save: function() {
    if (this.needsSave()) {
      return this.onEnter();
    } else {
      return Promise.resolve();
    }
  },
  
  shouldComponentUpdate: function(nextProps, nextState) {
    var nextNum = keypath(nextProps, "issue.number");
    var oldNum = keypath(this.props, "issue.number");
    
    if (nextNum && nextNum == oldNum && this.refs.completer.isEdited()) {
      return false;
    }
    return true;
  },
    
  render: function() {
    var ls = IssueState.current.assignees.map((a) => {
      var lowerLogin = a.login.toLowerCase();
      var lowerName = null;
      if (a.name != null) {
        lowerName = a.name.toLowerCase();
      }
      return Object.assign({}, a, { lowerLogin: lowerLogin, lowerName: lowerName });
    });
    
    ls.sort((a, b) => a.lowerLogin.localeCompare(b.lowerLogin));
    
    var matcher = (q, cb) => {
      var yieldAssignees = function(a) {
        cb(a.map((x) => x.login));
      };
      
      q = q.toLowerCase();
        
      if (q === '') {
        yieldAssignees(ls);
        return;
      }
      
      var matches = ls.filter((a) => {
        var lowerLogin = a.lowerLogin;
        var lowerName = a.lowerName;
        
        return lowerLogin.indexOf(q) != -1 ||
          (lowerName != null && lowerName.indexOf(q) != -1);
      });
          
      yieldAssignees(matches);      
    };
    
    return h(Completer, {
      ref: 'completer',
      placeholder: 'Unassigned', 
      onChange: this.assigneeChanged,
      onEnter: this.onEnter,
      value: keypath(this.props.issue, "assignees[0].login"),
      matcher: matcher
    });
  }
});

var AddAssignee = React.createClass({
  propTypes: {
    issue:React.PropTypes.object,
  },
  
  addAssignee: function(login) {
    var user = null;
    var matches = IssueState.current.assignees.filter((u) => u.login == login);
    if (matches.length > 0) {
      user = matches[0];
      var assignees = [user, ...this.props.issue.assignees];
      return IssueState.current.patchIssue({assignees});
    }
  },
  
  focus: function() {
    if (this.refs.picker) {
      this.refs.picker.focus();
    }
  },
  
  hasFocus: function() {
    if (this.refs.picker) {
      return this.refs.picker.hasFocus();
    } else {
      return false;
    }
  },
  
  needsSave: function() {
    if (this.refs.picker) {
      return this.refs.picker.containsCompleteValue();
    } else {
      return false;
    }
  },
  
  save: function() {
    if (this.needsSave()) {
      return this.refs.picker.addLabel();
    } else {
      return Promise.resolve();
    }
  },
  
  render: function() {
    var allAssignees = IssueState.current.assignees;
    var chosenAssignees = keypath(this.props.issue, "assignees") || [];
    
    var chosenAssigneesLookup = chosenAssignees.reduce((o, l) => { o[l.login] = l; return o; }, {});
    var availableAssignees = allAssignees.filter((l) => !(l.login in chosenAssigneesLookup));

    if (this.props.issue._bare_owner == null ||
        this.props.issue._bare_repo == null) {
      return h("span", {className: "AddAssigneesEmpty"});
    } else {
      return h(AssigneesPicker, {
        ref: "picker",
        availableAssigneeLogins: availableAssignees.map((l) => (l.login)),
        onAdd: this.addAssignee,
      });
    }
  }
});

var AssigneeAtom = React.createClass({
  propTypes: { 
    user: React.PropTypes.object.isRequired,
    onDelete: React.PropTypes.func,
  },
  
  onDeleteClick: function() {
    if (this.props.onDelete) {
      this.props.onDelete(this.props.user);
    }
  },
  
  render: function() {
    return h("span", {className:"AssigneeAtom"},
      h("span", {className:"AssigneeAtomName"},
        this.props.user.login
      ),
      h('span', {className:'AssigneeAtomDelete Clickable', onClick:this.onDeleteClick}, 
        h('i', {className:'fa fa-times'})
      )
    );
  }
});

var MultipleAssignees = React.createClass({
  propTypes: { issue: React.PropTypes.object },
  
  deleteAssignee: function(user) {
    var assignees = this.props.issue.assignees.filter((u) => (u != user));
    IssueState.current.patchIssue({assignees});
  },
  
  focus: function() {
    if (this.refs.add) {
      this.refs.add.focus();
    }
  },
  
  hasFocus: function() {
    if (this.refs.add) {
      return this.refs.add.hasFocus();
    } else {
      return false;
    }
  },
  
  needsSave: function() {
    if (this.refs.add) {
      return this.refs.add.needsSave();
    } else {
      return false;
    }
  },
  
  save: function() {
    if (this.refs.add && this.refs.add.needsSave()) {
      return this.refs.add.save();
    } else {
      return Promise.resolve();
    }
  },
  
  render: function() {
    // this is lame, but it's what GitHub does: sorts em by identifier
    var sortedAssignees = [...this.props.issue.assignees].sort((a, b) => {
      if (a.id < b.id) { return -1; }
      else if (a.id > b.id) { return 1; }
      else { return 0; }
    });
    
    return h('span', {className:'MultipleAssignees'},
      h(AddAssignee, {issue: this.props.issue, ref:"add"}),
      sortedAssignees.map((l, i) => { 
        return [" ", h(AssigneeAtom, {key:i, user:l, onDelete: this.deleteAssignee})];
      }).reduce(function(c, v) { return c.concat(v); }, [])
    );
  }
});

var AssigneeField = React.createClass({
  propTypes: {
    issue: React.PropTypes.object
  },
  
  getInitialState: function() {
    var assignees = keypath(this.props.issue, "assignees") || [];
    return { multi: assignees.length > 1 };
  },
  
  componentWillReceiveProps: function(nextProps) {
    var nextNum = keypath(nextProps, "issue.number");
    var oldNum = keypath(this.props, "issue.number");
    
    var assignees = keypath(nextProps, "issue.assignees") || [];
    if ((oldNum && nextNum != oldNum) || assignees.length > 1) {
      this.setState({ multi: assignees.length > 1 });
    }
  },

  focus: function() {
    if (this.refs.assignee) {
      this.refs.assignee.focus();
    }
  },
  
  hasFocus: function() {
    if (this.refs.assignee) {
      return this.refs.assignee.hasFocus();
    } else {
      return false;
    }
  },
  
  needsSave: function() {
    if (this.refs.assignee) {
      return this.refs.assignee.needsSave();
    } else {
      return false;
    }
  },
  
  save: function() {
    if (this.refs.assignee) {
      return this.refs.assignee.save();
    } else {
      return Promise.resolve();
    }
  },
  
  toggleMultiAssignee: function() {
    this.goingMulti = true;
    this.setState({multi: true});
  },

  render: function() {
    var inputField;
    if (this.state.multi) {
      inputField = h(MultipleAssignees, {key:'assignees', ref:'assignee', issue:this.props.issue, focusNext:this.props.focusNext});
    } else {
      inputField = h(AssigneeInput, {key:'assignee', ref:"assignee", issue: this.props.issue, focusNext:this.props.focusNext});
    }
  
    return h('div', {className: 'IssueInput AssigneeField'},
      h(HeaderLabel, {title:this.state.multi?"Assignees":"Assignee"}),
      inputField,
      h('i', {
        className:"fa fa-user-plus toggleMultiAssignee",
        style: {display: this.state.multi?"none":"inline"},
        title: "Multiple Assignees",
        onClick: this.toggleMultiAssignee
      })
    );
  },
  
  componentDidUpdate: function() {
    if (this.goingMulti) {
      this.goingMulti = false;
      this.focus();
    }
  }
});

var AddLabel = React.createClass({
  propTypes: { 
    issue: React.PropTypes.object,
  },
  
  addExistingLabel: function(label) {
    var labels = [label, ...this.props.issue.labels];
    return IssueState.current.patchIssue({labels: labels});
  },

  newLabel: function(prefillName) {
    return new Promise((resolve, reject) => {
      window.newLabel(prefillName ? prefillName : "",
                      IssueState.current.labels,
                      this.props.issue._bare_owner,
                      this.props.issue._bare_repo,
                      (succeeded, label) => {
                        this.focus();
                        if (succeeded) {
                          IssueState.current.labels.push({
                            name: label.name,
                            color: label.color,
                          });
                          this.forceUpdate();

                          return this.addExistingLabel(label).then(resolve, reject);
                        }
                        resolve();
                      });
    });
  },

  focus: function() {
    if (this.refs.picker) {
      this.refs.picker.focus();
    }
  },
  
  hasFocus: function() {
    if (this.refs.picker) {
      return this.refs.picker.hasFocus();
    } else {
      return false;
    }
  },
  
  needsSave: function() {
    if (this.refs.picker) {
      return this.refs.picker.containsCompleteValue();
    } else {
      return false;
    }
  },
  
  save: function() {
    if (this.needsSave()) {
      return this.refs.picker.addLabel();
    } else {
      return Promise.resolve();
    }
  },
    
  render: function() {
    var allLabels = IssueState.current.labels;
    var chosenLabels = keypath(this.props.issue, "labels") || [];
    
    chosenLabels = [...chosenLabels].sort((a, b) => {
      return a.name.localeCompare(b.name);
    });
    
    var chosenLabelsLookup = chosenLabels.reduce((o, l) => { o[l.name] = l; return o; }, {});  
    var availableLabels = allLabels.filter((l) => !(l.name in chosenLabelsLookup));

    if (this.props.issue._bare_owner == null ||
        this.props.issue._bare_repo == null) {
      return h("div", {className: "AddLabelEmpty"});
    } else {
      return h(LabelPicker, {
        ref: "picker",
        chosenLabels: chosenLabels,
        availableLabels: availableLabels,
        onAddExistingLabel: this.addExistingLabel,
        onNewLabel: this.newLabel,
      });
    }
  }
});

var IssueLabels = React.createClass({
  propTypes: { issue: React.PropTypes.object },
  
  deleteLabel: function(label) {
    var labels = this.props.issue.labels.filter((l) => (l.name != label.name));
    IssueState.current.patchIssue({labels: labels});
  },
  
  focus: function() {
    if (this.refs.add) {
      this.refs.add.focus();
    }
  },
  
  hasFocus: function() {
    if (this.refs.add) {
      return this.refs.add.hasFocus();
    } else {
      return false;
    }
  },
  
  needsSave: function() {
    if (this.refs.add) {
      return this.refs.add.needsSave();
    } else {
      return false;
    }
  },
  
  save: function() {
    if (this.refs.add && this.refs.add.needsSave()) {
      return this.refs.add.save();
    } else {
      return Promise.resolve();
    }
  },
  
  render: function() {
    return h('div', {className:'IssueLabels'},
      h(HeaderLabel, {title:"Labels"}),
      h(AddLabel, {issue: this.props.issue, ref:"add"}),
      this.props.issue.labels.map((l, i) => { 
        return [" ", h(Label, {key:i, label:l, canDelete:true, onDelete: this.deleteLabel})];
      }).reduce(function(c, v) { return c.concat(v); }, [])
    );
  }
});

var Header = React.createClass({
  propTypes: { 
    issue: React.PropTypes.object,
    onIssueTemplate: React.PropTypes.func
  },
  
  focus: function() {
    this.focusField('title');
  },
  
  focussed: function() {
    if (this.queuedFocus) {
      return this.queuedFocus;
    }
    
    var a = ["title", "repo", "milestone", "assignee", "labels"];
    
    for (var i = 0; i < a.length; i++) {
      var n = a[i];
      var x = this.refs[n];
      if (x && x.hasFocus()) {
        return n;
      }
    }
    
    return null;
  },
  
  focusField: function(field) {
    if (this.refs[field]) {
      var x = this.refs[field];
      x.focus();
    } else {
      this.queuedFocus = field;
    }
  },
  
  focusNext: function(current) {
    var next = null;
    switch (current) {
      case "title": next = "repo"; break;
      case "repo": next = "milestone"; break;
      case "milestone": next = "assignee"; break;
      case "assignee": next = "labels"; break;
      case "labels": next = "labels"; break;
    }
    
    this.focusField(next);
  },
  
  dequeueFocus: function() {
    if (this.queuedFocus) {
      var x = this.refs[this.queuedFocus];
      this.queuedFocus = null;
      x.focus();
    }
  },
  
  componentDidMount: function() {
    this.dequeueFocus();
  },
  
  componentDidUpdate: function() {
    this.dequeueFocus();
  },
  
  needsSave: function() {
//     console.log("header needsSave: ", 
//       {"title": this.refs.title.needsSave()},
//       {"repo": this.refs.repo.needsSave()},
//       {"milestone": this.refs.milestone.needsSave()},
//       {"assignee": this.refs.assignee.needsSave()},
//       {"labels": this.refs.labels.needsSave()}
//     );
  
    return (
      this.refs.title.needsSave()
      || this.refs.repo.needsSave()
      || this.refs.milestone.needsSave()
      || this.refs.assignee.needsSave()
      || this.refs.labels.needsSave()
    );
  },
  
  save: function() {
    var promises = [];
    for (var k in this.refs) {
      var r = this.refs[k];
      if (r && r.needsSave && r.needsSave()) {
        promises.push(r.save());
      }      
    }
    return Promise.all(promises);
  },
  
  render: function() {
    var hasRepo = this.props.issue._bare_repo && this.props.issue._bare_owner;
    var els = [];
    
    els.push(h(IssueTitle, {key:"title", ref:"title", issue: this.props.issue, focusNext:this.focusNext}),
             h(HeaderSeparator, {key:"sep0"}),
             h(RepoField, {key:"repo", ref:"repo", issue: this.props.issue, focusNext:this.focusNext, onIssueTemplate:this.props.onIssueTemplate}));
             
    els.push(h(HeaderSeparator, {key:"sep1"}),
             h(MilestoneField, {key:"milestone", ref:"milestone", issue: this.props.issue, focusNext:this.focusNext}),
             h(HeaderSeparator, {key:"sep2"}),
             h(AssigneeField, {key:"assignee", ref:"assignee", issue: this.props.issue, focusNext:this.focusNext}),
             h(HeaderSeparator, {key:"sep3"}),
             h(IssueLabels, {key:"labels", ref:"labels", issue: this.props.issue}));
  
    return h('div', {className: 'IssueHeader'}, els);
  }
});

function simpleFetch(url) {
  return api(url, { headers: { Authorization: "token " + IssueState.current.token }, method: "GET" });
}
      
function pagedFetch(url) /* => Promise */ {
  if (window.inApp) {
    return simpleFetch(url);
  }

  var opts = { headers: { Authorization: "token " + IssueState.current.token }, method: "GET" };
  var initial = fetch(url, opts);
  return initial.then(function(resp) {
    var pages = []
    var link = resp.headers.get("Link");
    if (link) {
      var [next, last] = link.split(", ");
      var matchNext = next.match(/\<(.*?)\>; rel="next"/);
      var matchLast = last.match(/\<(.*?)\>; rel="last"/);
      if (matchNext && matchLast) {
        var second = parseInt(matchNext[1].match(/page=(\d+)/)[1]);
        var last = parseInt(matchLast[1].match(/page=(\d+)/)[1]);
        for (var i = second; i <= last; i++) {
          var pageURL = matchNext[1].replace(/page=\d+/, "page=" + i);
          pages.push(fetch(pageURL, opts).then(function(resp) { return resp.json(); }));
        }
      }
    }
    return Promise.all([resp.json()].concat(pages));
  }).then(function(pages) {
    return pages.reduce(function(a, b) { return a.concat(b); });
  });
}

function loadMetadata(repoFullName) {
  var owner = null;
  var repo = null;
  
  if (repoFullName) {
    [owner, repo] = repoFullName.split("/");
  }

  var reqs = [pagedFetch("https://api.github.com/user/repos"),
              simpleFetch("https://api.github.com/user")];
              
  if (owner && repo) {
    reqs.push(pagedFetch("https://api.github.com/repos/" + owner + "/" + repo + "/assignees"),
              pagedFetch("https://api.github.com/repos/" + owner + "/" + repo + "/milestones"),
              pagedFetch("https://api.github.com/repos/" + owner + "/" + repo + "/labels"));
  }
  
  return Promise.all(reqs).then(function(parts) {
    var meta = {
      repos: parts[0].filter((r) => r.has_issues),
      me: parts[1],
      assignees: (parts.length > 2 ? parts[2] : []),
      milestones: (parts.length > 3 ? parts[3] : []),
      labels: (parts.length > 4 ? parts[4] : []),
      token: IssueState.current.token,
    };
    
    return new Promise((resolve, reject) => {
      resolve(meta);
    });
  }).catch(function(err) {
    console.log(err);
  });
}

var App = React.createClass({
  propTypes: { issue: React.PropTypes.object },
  
  render: function() {
    var issue = this.props.issue;

    var header = h(Header, {ref:"header", issue: issue, onIssueTemplate:this.onIssueTemplate});
    var activity = h(ActivityList, {key:issue["id"], ref:"activity", issue:issue});
    var addComment = h(Comment, {ref:"addComment", key:"addComment"});
    
    var issueElement = h('div', {},
      header,
      activity,
      addComment
    );
        
    return issueElement;
  },
  
  onIssueTemplate: function(template) {
    var addComment = this.refs.addComment;
    if (addComment) {
      addComment.setInitialContents(template);
    }
  },
  
  allComments: function() {
    if (this.refs.addComment && this.refs.activity) {
      var comments = this.refs.activity.allComments().concat([this.refs.addComment]);
      return comments;
    } else {
      return [];
    }
  },
  
  restoreCommentDrafts: function() {
    this.allComments().forEach((c) => c.restoreDraftState());
  },
  
  saveCommentDrafts: function() {
    this.allComments().forEach((c) => c.saveDraftState());
  },
  
  componentDidMount: function() {
    this.registerGlobalEventHandlers();
    
    // If we're doing New Clone in the app, we have an issue body already.
    // Set it, but don't dirty the save state
    var isNewIssue = !(IssueState.current.issue.number);
    var addComment = this.refs.addComment;
    if (isNewIssue && this.props.issue && this.props.issue.body && this.props.issue.body.length > 0) {
      addComment.setInitialContents(this.props.issue.body);
    }
  },
  
  componentDidUpdate: function() {
    this.registerGlobalEventHandlers();  
  },
  
  needsSave: function() {
    var l = [this.refs.header, this.refs.activity, this.refs.addComment];
    var edited = l.reduce((a, x) => a || x.needsSave(), false)
    var isNewIssue = !(IssueState.current.issue.number);
    var isEmptyNewIssue = IssueState.current.issue.title == null || IssueState.current.issue.title == "";
    return edited || (isNewIssue && !isEmptyNewIssue);
  },
  
  save: function() {
    var isNewIssue = !(this.props.issue.number);
    if (isNewIssue) {
      this.refs.header.save(); // commit any pending changes      
      var title = IssueState.current.issue.title;
      var repo = IssueState.current.repoName;
      
      if (!title || title.trim().length == 0) {
        var reason = "Cannot save issue. Title is required.";
        alert(reason);
        return Promise.reject(reason);
      } else if (!repo || repo.trim().length == 0) {
        var reason = "Cannot save issue. Repo is required."
        alert(reason);
        return Promise.reject(reason);
      } else {
        return this.refs.addComment.save();
      }
    } else {
      var l = [this.refs.header, this.refs.activity, this.refs.addComment];
      var promises = l.filter((x) => x.needsSave()).map((x) => x.save());
      return Promise.all(promises);
    }
  },
  
  registerGlobalEventHandlers: function() {
    var doc = window.document;
    doc.onkeypress = (evt) => {
      if (evt.which == 115 && evt.metaKey && !evt.shiftKey && !evt.ctrlKey && !evt.altKey) {
        console.log("global save");
        this.save();
        evt.preventDefault();
      }
    };
  },
  
  activeComment: function() {
    var activity = this.refs.activity;
    var addComment = this.refs.addComment;
    
    if (activity && addComment) {
      var c = activity.activeComment();
      if (!c) {
        c = addComment;
      }
      return c;
    }
    
    return null;
  },
  
  applyMarkdownFormat: function(format) {
    var c = this.activeComment();
    if (c) { 
      c.applyMarkdownFormat(format);
    }
  },
  
  toggleCommentPreview: function() {
    var c = this.activeComment();
    if (c) {
      c.togglePreview();
    }
  },
  
  scrollToCommentWithIdentifier: function(commentID) {
    var activity = this.refs.activity;
    if (activity) {
      activity.scrollToCommentWithIdentifier(commentID);
    }
  },
  
  focus: function() {
    var header = this.refs.header;
    if (header) {
      header.focus();
    }
  }
});

function applyIssueState(state, scrollToCommentIdentifier) {
  var oldOwner, oldRepo, oldNum;
  oldOwner = IssueState.current.repoOwner;
  oldRepo = IssueState.current.repoName;
  oldNum = IssueState.current.issueNumber;
  
  if (oldOwner && oldRepo && oldNum && window.topLevelComponent && !window.lastErr) {
    window.topLevelComponent.saveCommentDrafts();
  }

  console.log("rendering:", state);
  
  var issue = state.issue;
  
  window.document.title = issue.title || "New Issue";
  
  if (issue.repository_url) {
    var comps = issue.repository_url.replace("https://", "").split("/");
    issue._bare_owner = comps[comps.length-2]
    issue._bare_repo = comps[comps.length-1]
  } else {
    if (issue.repository) {
      var comps = issue.repository.full_name.split("/");
      issue._bare_owner = comps[0];
      issue._bare_repo = comps[1];
    }
  }
    
  if (issue.originator) {
    issue.user = issue.originator;
  }
  
  var allPossibleAssignees = state.assignees.map((a) => a.login);
  var allPossibleCommenters = (issue.comments || []).filter((c) => !!keypath(c, "user.login")).map((c) => c.user.login)
  if (keypath(issue, "user.login")) {
    allPossibleCommenters.push(issue.user.login);
  }
  var allLogins = Array.from(new Set(allPossibleAssignees.concat(allPossibleCommenters)));
  allLogins = allLogins.map((s) => ({ v:s, l:s }));
  allLogins.sort((a, b) => a.l.localeCompare(b.l));
  allLogins = allLogins.map((o) => o.v);
  state.allLoginCompletions = allLogins;
  
  IssueState.current.state = state;
  
  var newOwner, newRepo, newNum;
  newOwner = IssueState.current.repoOwner;
  newRepo = IssueState.current.repoName;
  newNum = IssueState.current.issueNumber;
  
  var shouldRestoreDrafts = (newOwner != oldOwner || newRepo != oldRepo || newNum != oldNum);
  
  if (window.lastErr) {
    console.log("Rerendering everything");
    delete window.lastErr;
    var node = document.getElementById('react-app');
    try {
      ReactDOM.unmountComponentAtNode(node);
    } catch (exc) {
      node.remove();
      var body = document.getElementsByTagName('body')[0];
      node = document.createElement('div');
      node.setAttribute('id', 'react-app');
      body.appendChild(node);
    }
  }
  
  window.topLevelComponent = ReactDOM.render(
    h(App, {issue: issue}),
    document.getElementById('react-app'),
    function() {
      if (scrollToCommentIdentifier) {
        setTimeout(function() {        
          window.scrollToCommentWithIdentifier(scrollToCommentIdentifier);
        }, 0);
      }
      if (shouldRestoreDrafts) {
        setTimeout(function() {
          if (window.topLevelComponent) {
            window.topLevelComponent.restoreCommentDrafts();
          }
        }, 0);
      }
    }
  )
}
IssueState.current.applyIssueState = applyIssueState;

function scrollToCommentWithIdentifier(scrollToCommentIdentifier) {
  if (window.topLevelComponent) {
    window.topLevelComponent.scrollToCommentWithIdentifier(scrollToCommentIdentifier);
  }
}

function configureNewIssue(initialRepo, meta) {
  if (!meta) {
    loadMetadata(initialRepo).then((meta) => {
      configureNewIssue(initialRepo, meta);
    }).catch((err) => {
      console.log("error rendering new issue", err);
    });
    return;
  }
  
  var owner = null, repo = null;
  
  if (initialRepo) {
    [owner, repo] = initialRepo.split("/");
  }
  
  var issue = {
    title: "",
    state: "open",
    milestone: null,
    assignees: [],
    labels: [],
    comments: [],
    events: [],
    _bare_owner: owner,
    _bare_repo: repo,
    user: meta.me
  };
  
  var state = Object.assign({}, meta, {
    issue: issue
  });
  
  applyIssueState(state);
}

window.applyIssueState = applyIssueState;
window.scrollToCommentWithIdentifier = scrollToCommentWithIdentifier;
window.configureNewIssue = configureNewIssue;

window.needsSave = function() {
  return window.topLevelComponent && window.topLevelComponent.needsSave();
}

window.save = function(token) {
  if (window.topLevelComponent) {
    var p = window.topLevelComponent.save();
    if (window.documentSaveHandler) {
      if (p) {
        p.then(function(success) {
          window.documentSaveHandler.postMessage({token:token, error:null});
        }).catch(function(error) {
          window.documentSaveHandler.postMessage({token:token, error:error});
        });
      } else {
        window.documentSaveHandler.postMessage({token:token, error:null});
      }
    }
  }
}

function findCSSRule(selector) {
  var sheets = document.styleSheets;
  for (var i = 0; i < sheets.length; i++) {
    var rules = sheets[i].cssRules;
    for (var j = 0; j < rules.length; j++) {
      if (rules[j].selectorText == selector) {
        return rules[j];
      }
    }
  }
  return null;
}

function setInColumnBrowser(inBrowser) {
  window.inColumnBrowser = inBrowser;
  
  var body = document.getElementsByTagName('body')[0];
  body.style.padding = inBrowser ? '14px' : '0px';
  
  var commentRule = findCSSRule('div.comment');
  commentRule.style.borderLeft = inBrowser ? commentRule.style.borderTop : '0px';
  commentRule.style.borderRight = inBrowser ? commentRule.style.borderTop : '0px';
  
  var headerRule = findCSSRule('div.IssueHeader');
  headerRule.style.borderLeft = inBrowser ? headerRule.style.borderBottom : '0px';
  headerRule.style.borderRight = inBrowser ? headerRule.style.borderBottom : '0px';
  headerRule.style.borderTop = inBrowser ? headerRule.style.borderBottom : '0px';
}

window.setInColumnBrowser = setInColumnBrowser;

function applyMarkdownFormat(format) {
  if (window.topLevelComponent) {
    window.topLevelComponent.applyMarkdownFormat(format);
  } 
}

window.applyMarkdownFormat = applyMarkdownFormat;

function toggleCommentPreview() {
  if (window.topLevelComponent) {
    window.topLevelComponent.toggleCommentPreview();
  }
}
window.toggleCommentPreview = toggleCommentPreview;

function focusIssue() {
  if (window.topLevelComponent) {
    window.topLevelComponent.focus();
  }
}
window.focusIssue = focusIssue;

if (__DEBUG__) {
  console.log("*** Debug build ***");
}

window.onerror = function() {
  window.lastErr = true;
}

window.onload = function() {
  window.loadComplete.postMessage({});
}