
%%%------------------------------------------------------------------------
%% Copyright The OpenTelemetry Authors
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%%-------------------------------------------------------------------------

%% The ID of the change (pull request/merge request) if applicable. This is usually a unique (within repository) identifier generated by the VCS system.
%%  
-define(VCS_REPOSITORY_CHANGE_ID, 'vcs.repository.change.id').


%% The human readable title of the change (pull request/merge request). This title is often a brief summary of the change and may get merged in to a ref as the commit summary.
%%  
-define(VCS_REPOSITORY_CHANGE_TITLE, 'vcs.repository.change.title').


%% The name of the [reference](https://git-scm.com/docs/gitglossary#def_ref) such as **branch** or **tag** in the repository.
%%  
-define(VCS_REPOSITORY_REF_NAME, 'vcs.repository.ref.name').


%% The revision, literally [revised version](https://www.merriam-webster.com/dictionary/revision), The revision most often refers to a commit object in Git, or a revision number in SVN.
%%  
-define(VCS_REPOSITORY_REF_REVISION, 'vcs.repository.ref.revision').


%% The type of the [reference](https://git-scm.com/docs/gitglossary#def_ref) in the repository.
%%  
-define(VCS_REPOSITORY_REF_TYPE, 'vcs.repository.ref.type').

-define(VCS_REPOSITORY_REF_TYPE_VALUES_BRANCH, 'branch').

-define(VCS_REPOSITORY_REF_TYPE_VALUES_TAG, 'tag').



%% The [URL](https://en.wikipedia.org/wiki/URL) of the repository providing the complete address in order to locate and identify the repository.
%%  
-define(VCS_REPOSITORY_URL_FULL, 'vcs.repository.url.full').
