import 'components/comment/comment.css'
import './comment.css'

import DiffRow from './diff-row.js'
import MiniMap from './minimap.js'

import AbstractComment from 'components/comment/AbstractComment.js'
import ghost from 'util/ghost.js'

import React, { createElement as h } from 'react'
import ReactDOM from 'react-dom'

import uuidV4 from 'uuid/v4.js'

class Comment extends AbstractComment {
  constructor(props) {
    super(props);
  }
  
  issueIdentifierParts() {
    var [repoOwner, repoName, number] = this.props.issueIdentifier.split("/#");
    return { repoOwner, repoName, number };
  }
  
  issue() {
    var { number } = this.issueIdentifierParts();
    return {
      number: number
    }
  }
  
  isNewIssue() { return false; }
  
  me() { return this.props.me; }
  
  canClose() { return false; }
  
  repoOwner() {
    return this.issueIdentifierParts().repoOwner;
  }
  
  repoName() {
    return this.issueIdentifierParts().repoName;
  }
  
  shouldShowCommentPRBar() { return false; }
  
  saveDraftState() { }
  restoreDraftState() { }
  
  deleteComment() {
    this.props.commentDelegate.deleteComment(this.props.comment);
    return Promise.resolve();
  }
  
  saveAndClose() { return this.save(); }
  
  loginCompletions() { return [] }
  
  _save() {
    if (this.props.comment) {
      var newBody = this.state.code;
      if (newBody != this.props.comment.body) {
        var newComment = Object.assign({}, this.props.comment, {body:newBody});
        this.props.commentDelegate.editComment(newComment);
      }
      this.setState(Object.assign({}, this.state, {editing:false}));
    } else {
      var now = new Date().toISOString();
      var newComment = {
        pending_id: uuidV4(),
        user: this.props.me,
        body: this.state.code,
        created_at: now,
        updated_at: now,
        reactions: [],
      }
      if (this.props.inReplyTo && !!(this.props.inReplyTo.id)) {
        newComment.in_reply_to = this.props.inReplyTo.id;
      } else {
        newComment.diffIdx = this.props.diffIdx;
      }
      this.props.commentDelegate.addNewComment(newComment);
    }
    
    if (this.props.didSave) {
      this.props.didSave();
    }
    return Promise.resolve();
  }
  
  onTaskListEdit(newBody) {
    if (!this.props.comment || this.state.editing) {
      this.updateCode(newBody);
    } else {
      var newComment = Object.assign({}, this.props.comment, {body:newBody});
      this.props.commentDelegate.editComment(newComment);
    }
  }
  
  componentDidMount() {
    super.componentDidMount();
    if (!this.props.comment) {
      this.focusCodemirror();
    }
    this.props.didRender();
  }
  
  componentDidUpdate() {
    super.componentDidUpdate();
    this.props.didRender();
  }
}

class ReviewFooter extends React.Component {
  render() {
    var canSave = this.props.canSave;
    var contents = [];
    
    if (!this.props.previewing) {
      contents.push(h('a', {
        key:'markdown', 
        className:'markdown-mark formattingHelpButton', 
        target:"_blank", 
        href:"https://guides.github.com/features/mastering-markdown/", 
        title:"Open Markdown Formatting Guide"
      }));
    }
    
    contents.push(h('div', {
      key:'cancel', 
      className:'Clickable addCommentButton addCommentCloseButton', 
      onClick:this.props.onCancel}, 
      'Cancel'
    ));
    
    if (!this.props.inReview) {
      contents.push(h('div', {
        key:'addSingle',
        title:'⌘⇧↩︎', 
        className:'Clickable addCommentButton', 
        onClick:this.props.onAddSingleComment}, 
        'Add Single Comment'
      ));
    }
    
    contents.push(h('div', {
      key:'addReview',
      title:'⌘↩︎', 
      className:'Clickable addCommentButton addCommentSaveButton', 
      onClick:this.props.onSave}, 
      this.props.inReview?'Add review comment':'Start a review'
    ));
    
    return h('div', {className:'commentFooter'}, contents);
  }
}

class AddReviewComment extends Comment {
  save() {
    // default behavior is to begin a review
    this.props.commentDelegate.inReview = true;
    super.save();
  }
  
  saveAndClose() {
    // this is repurposed to mean add single comment
    super.save();
  }
  
  renderFooter() {
    if (this.state.uploadCount > 0) {
      return super.renderFooter();
    } else {
      return h(ReviewFooter, {
        previewing: this.state.previewing,
        inReview: this.props.commentDelegate.inReview,
        canSave: this.needsSave(),
        onAddSingleComment: this.saveAndClose.bind(this),
        onSave: this.save.bind(this),
        onCancel: this.props.onCancel
      });
    }
  }
}

class CommentList extends React.Component {
  constructor(props) {
    super(props);
    this.state = { hasReply: this.props.comments.length == 0 }
  }
  
  addReply() {
    if (!this.state.hasReply) {
      this.needsScrollAddComment = true;
      this.setState(Object.assign({}, this.state, {hasReply: true}));
    } else {
      this.refs.addComment.focusCodemirror();
    }
  }
  
  cancelReply() {
    this.setState(Object.assign({}, this.state, {hasReply: false}));
    this.props.didCancel();
  }
    
  render() {
    var commentsLength = this.props.comments.length;
    var buttonIdx = this.state.hasReply ? -1 : commentsLength - 1;
    var comments = this.props.comments.map((c, i) => {
      return h(Comment, {
        key:c.id||c.pending_id||c.created_at, 
        ref:'comment.' + (c.id||c.pending_id||c.created_at),
        comment:c, 
        first:false,
        commentIdx:i,
        issueIdentifier:this.props.issueIdentifier,
        me:this.props.me,
        buttons:i==buttonIdx?[{"title": "Reply", "action": this.addReply.bind(this)}]:[],
        didRender:this.props.didRender,
        commentDelegate:this.props.commentDelegate,
        diffIdx:this.props.diffIdx
      })
    });
        
    if (this.state.hasReply) {
      comments.push(h(AddReviewComment, {
        key:'add',
        ref:'addComment',
        issueIdentifier:this.props.issueIdentifier,
        me:this.props.me,
        onCancel:this.cancelReply.bind(this),
        didRender:this.props.didRender,
        inReplyTo:commentsLength>0?this.props.comments[commentsLength-1]:undefined,
        commentDelegate:this.props.commentDelegate,
        didSave:this.cancelReply.bind(this),
        diffIdx:this.props.diffIdx
      }));
    }
  
    return h('div', {className:'commentList'},
      comments
    );
  }
  
  scrollToComment(c) {
    var ref = 'comment.' + (c.id||c.pending_id||c.created_at);
    if (ref in this.refs) {
      var comp = this.refs[ref];
      comp.scrollIntoView();
    }
  }
  
  componentDidUpdate() {
    this.props.didRender();
    if (this.needsScrollAddComment && this.refs.addComment) {
      this.needsScrollAddComment = false;
      this.refs.addComment.scrollIntoView();
    }
  }
  
  componentDidMount() {
    this.props.didRender();
  }
}

class CommentRow extends DiffRow {
  constructor(issueIdentifier, me, delegate) {
    super();
    
    this.issueIdentifier = issueIdentifier;
    this.me = me;
    this.delegate = delegate;

    this.hasNewComment = false;    
    this.prComments = []; // Array of PRComments
    
    var commentsContainer = this.commentsContainer = document.createElement('div');
    commentsContainer.className = 'commentsContainer';
    
    var commentBlock = document.createElement('div');
    commentBlock.className = 'commentBlock';
    
    var shadowTop = document.createElement('div');
    shadowTop.className = 'commentShadowTop';
    
    var shadowBottom = document.createElement('div');
    shadowBottom.className = 'commentShadowBottom';
    
    commentBlock.appendChild(shadowTop);
    commentBlock.appendChild(commentsContainer);
    commentBlock.appendChild(shadowBottom);
    
    this._colspan = 1;
    var td = document.createElement('td');
    td.className = 'comment-cell';
    td.appendChild(commentBlock);
    this.cell = td;
    
    var row = document.createElement('tr');
    row.appendChild(td);
    this.node = row;
    
    this.miniMapRegions = [new MiniMap.Region(commentsContainer, 'purple')];
  }
    
  set colspan(x) {
    if (this._colspan != x) {
      this._colspan = x;
      this.cell.colSpan = x;
    }
  }
  
  get colspan() {
    return this._colspan;
  }
  
  set comments(comments /*[PRComment]*/) {
    this.prComments = comments;
    this.render();
  }
  
  get comments() {
    return this.prComments;
  }
  
  get diffIdx() {
    if (this.prComments.length == 0) {
      if (this.newCommentDiffIdx !== undefined) {
        return this.newCommentDiffIdx;
      }
      return -1;
    }
    
    return this.prComments[0].diffIdx;
  }
  
  setHasNewComment(flag, diffIdx) {
    this.hasNewComment = flag;
    if (flag) {
      this.newCommentDiffIdx = diffIdx;
    } else {
      delete this.newCommentDiffIdx;
    }
    this.render(() => {
      setTimeout(() => this.showReply(), 0);
    });
  }
    
  showReply() {
    if (this.commentList) {
      this.commentList.addReply();
    }
  }
  
  didCancelReply() {
    if (this.prComments.length == 0) {
      this.delegate.cancelInsertComment(this.diffIdx);
    }
  }
  
  render(then) {
    this.commentList = ReactDOM.render(
      h(CommentList, {
        comments:this.prComments,
        issueIdentifier:this.issueIdentifier,
        me:this.me,
        didRender:()=>this.delegate.updateMiniMap(),
        didCancel:this.didCancelReply.bind(this),
        commentDelegate:this.delegate,
        diffIdx:this.diffIdx
      }),
      this.commentsContainer,
      then
    );
  }
  
  scrollToComment(comment) {
    setTimeout(() => {
      this.commentList.scrollToComment(comment);
    }, 1);
  }
}

export default CommentRow;